;; ------------------------------------------------------------
;; STX-Collateralized Stablecoin (sUSD) - Clarity v2 (compact)
;; ------------------------------------------------------------
;; - Users deposit STX collateral to mint sUSD (1 sUSD equals 1 USD target)
;; - Requires oracle for STX/USD price (price scaled by PRICE_SCALE)
;; - Enforces minimum collateralization ratio of 150 percent
;; - Supports deposit, withdraw, mint, burn (repay), and liquidation
;; - Includes minimal SIP-010 read functions and transfer
;; ------------------------------------------------------------

(define-constant TOKEN-NAME "sUSD Stablecoin")
(define-constant TOKEN-SYMBOL "sUSD")
(define-constant TOKEN-DECIMALS u6) ;; token decimals (for UI)

;; --- Economic constants (tweakable) ---
(define-constant PRICE_SCALE u1000000)    ;; price units (1e6) -> 6 decimals
(define-constant MIN_COLLATERAL_BPS u15000) ;; 150% -> basis points (bps = /10000)
(define-constant LIQUIDATION_PENALTY_BPS u1000) ;; 10% penalty on collateral paid to liquidator

;; --- Errors ---
(define-constant ERR-UNAUTHORIZED (err u401))
(define-constant ERR-BAD-ARGS     (err u400))
(define-constant ERR-INSUFFICIENT (err u402))
(define-constant ERR-NOT-FOUND    (err u404))
(define-constant ERR-HEALTHY      (err u405))
(define-constant ERR-NOTHING      (err u406))

;; --- Admin / Oracle ---
(define-data-var owner principal tx-sender) ;; set at deploy
(define-data-var oracle principal tx-sender)
(define-data-var last-price uint u0)       ;; STX/USD price, scaled by PRICE_SCALE
(define-data-var last-price-height uint u0)

;; --- Token state (sUSD) ---
(define-data-var total-supply uint u0)
(define-map balances { who: principal } { amount: uint })

;; --- Collateral vaults: one vault per user ---
(define-map vaults
  { owner: principal }
  {
    collateral: uint, ;; amount of STX deposited
    debt: uint        ;; amount of sUSD minted (owed)
  })

;; ----------------- Helpers -----------------
(define-read-only (get-owner) (var-get owner))
(define-read-only (get-oracle) (var-get oracle))

;; Current block height
(define-read-only (now) u0) ;; TODO: Replace with actual block height once available

(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

(define-read-only (get-price)
  { price: (var-get last-price), height: (var-get last-price-height) })

(define-read-only (get-balance (who principal))
  (ok (default-to u0 (get amount (map-get? balances { who: who })))))

(define-read-only (get-total-supply) (ok (var-get total-supply)))

;; Calculate collateral value in USD scaled by PRICE_SCALE:
;; collateral_value_scaled = collateral_stx * price
(define-read-only (collateral-value-scaled (collateral uint))
  (mul-div collateral (var-get last-price) u1)) ;; kept scaled by PRICE_SCALE

;; Check health: returns collateralization ratio in BPS (collateral_value / debt * 10000)
(define-read-only (collateralization-bps (collateral uint) (debt uint))
  (if (is-eq debt u0)
      u999999999 ;; large sentinel for "inf" (no debt)
      (let ((coll-val (collateral-value-scaled collateral)))
        ;; coll-val is (STX * price). To compute ratio: (coll-val / (debt * PRICE_SCALE)) * 10000
        (mul-div coll-val u10000 (* debt PRICE_SCALE)))))

;; ----------------- Admin/Oracle functions -----------------
(define-public (set-oracle (who principal))
  (begin
    (asserts! (is-eq tx-sender (var-get owner)) ERR-UNAUTHORIZED)
    (asserts! (not (is-eq who (var-get oracle))) ERR-BAD-ARGS) ;; Only change if different
    (var-set oracle who)
    (ok who)))

(define-public (submit-price (price uint))
  (begin
    (asserts! (is-eq tx-sender (var-get oracle)) ERR-UNAUTHORIZED)
    (asserts! (> price u0) ERR-BAD-ARGS)
    (var-set last-price price)
    (var-set last-price-height (now))
    (ok price)))

;; ----------------- Collateral management -----------------
(define-public (deposit-collateral (amount uint))
  (begin
    (asserts! (> amount u0) ERR-BAD-ARGS)
    (asserts! (is-ok (stx-transfer? amount tx-sender (as-contract tx-sender))) ERR-INSUFFICIENT)
    (let ((v (default-to { collateral: u0, debt: u0 } (map-get? vaults { owner: tx-sender }))))
      (map-set vaults { owner: tx-sender } { collateral: (+ (get collateral v) amount), debt: (get debt v) })
      (ok true))))

(define-public (withdraw-collateral (amount uint))
  (let ((vault (unwrap! (map-get? vaults { owner: tx-sender }) ERR-NOT-FOUND)))
    (begin
      (asserts! (> amount u0) ERR-BAD-ARGS)
      (let ((coll (get collateral vault)) (debt (get debt vault)))
        (asserts! (>= coll amount) ERR-INSUFFICIENT)
        (let ((new-coll (- coll amount)))
          ;; check health after withdraw (if debt>0)
          (let ((ratio (collateralization-bps new-coll debt)))
            (asserts! (or (is-eq debt u0) (>= ratio MIN_COLLATERAL_BPS)) ERR-INSUFFICIENT)
            (map-set vaults { owner: tx-sender } { collateral: new-coll, debt: debt })
            (if (is-ok (stx-transfer? amount (as-contract tx-sender) tx-sender))
                (ok true)
                ERR-INSUFFICIENT)))))))

;; ----------------- Mint / Burn (sUSD) -----------------
(define-private (mint-internal (to principal) (amount uint))
  (let ((prev (default-to u0 (get amount (map-get? balances { who: to })))))
    (map-set balances { who: to } { amount: (+ prev amount) })
    (var-set total-supply (+ (var-get total-supply) amount))
    (ok true)))

(define-private (burn-internal (from principal) (amount uint))
  (let ((prev (default-to u0 (get amount (map-get? balances { who: from })))))
    (asserts! (>= prev amount) ERR-INSUFFICIENT)
    (map-set balances { who: from } { amount: (- prev amount) })
    (var-set total-supply (- (var-get total-supply) amount))
    (ok true)))

;; Mint sUSD against collateral (user must already have deposited collateral)
(define-public (mint (amount uint))
  (let ((vault (unwrap! (map-get? vaults { owner: tx-sender }) ERR-NOT-FOUND)))
    (begin
      (asserts! (> amount u0) ERR-BAD-ARGS)
      (let ((coll (get collateral vault)) (debt (get debt vault)))
        (let ((new-debt (+ debt amount)))
          ;; require collateralization after mint
          (let ((ratio (collateralization-bps coll new-debt)))
            (asserts! (>= ratio MIN_COLLATERAL_BPS) ERR-INSUFFICIENT)
            ;; mint tokens to user
            (unwrap-panic (mint-internal tx-sender amount))
            ;; update debt
            (map-set vaults { owner: tx-sender } { collateral: coll, debt: new-debt })
            (ok new-debt)))))))

;; Repay (burn) sUSD to lower debt and allow withdraws
(define-public (repay (amount uint))
  (let ((vault (unwrap! (map-get? vaults { owner: tx-sender }) ERR-NOT-FOUND)))
    (begin
      (asserts! (> amount u0) ERR-BAD-ARGS)
      ;; decrease token balance (burn)
      (unwrap-panic (burn-internal tx-sender amount))
      (let ((coll (get collateral vault)) (debt (get debt vault)))
        (let ((new-debt (if (>= debt amount) (- debt amount) u0)))
          (map-set vaults { owner: tx-sender } { collateral: coll, debt: new-debt })
          (ok new-debt))))))

;; ----------------- Liquidation -----------------
;; Anyone can liquidate an undercollateralized vault by paying up to the debt.
;; Liquidator repays 'repay-amount' sUSD on behalf of vault-owner, and receives
;; STX collateral equal to collateral_value_for_repaid * (1 - penalty).
(define-public (liquidate (target principal) (repay-amount uint))
  (let ((vault (unwrap! (map-get? vaults { owner: target }) ERR-NOT-FOUND))
        (liquidator-bal (default-to u0 (get amount (map-get? balances { who: tx-sender }))))
        (coll (get collateral vault))
        (debt (get debt vault)))
    
    ;; Validate inputs and state
    (asserts! (not (is-eq tx-sender target)) ERR-BAD-ARGS) ;; Can't liquidate own vault
    (asserts! (> debt u0) ERR-NOTHING)
    (asserts! (> repay-amount u0) ERR-BAD-ARGS)
    (asserts! (<= repay-amount debt) ERR-BAD-ARGS)
    (asserts! (>= liquidator-bal repay-amount) ERR-INSUFFICIENT)
    
    ;; Check health: must be undercollateralized
    (let ((ratio (collateralization-bps coll debt)))
      (asserts! (< ratio MIN_COLLATERAL_BPS) ERR-HEALTHY)
      
      ;; Burn liquidator's sUSD tokens
      (unwrap-panic (burn-internal tx-sender repay-amount))
      
      ;; Compute liquidation values
      (let ((collateral_for_repay (mul-div coll repay-amount debt))
            (penalty (mul-div collateral_for_repay LIQUIDATION_PENALTY_BPS u10000))
            (transfer-coll (- collateral_for_repay penalty)))
        
        ;; Final safety checks
        (asserts! (and (>= coll collateral_for_repay)
                      (>= collateral_for_repay penalty)
                      (> transfer-coll u0)) ERR-INSUFFICIENT)
        
        ;; Update vault state
        (map-set vaults { owner: target }
                { collateral: (- coll collateral_for_repay),
                  debt: (- debt repay-amount) })
        
        ;; Transfer collateral to liquidator
        (asserts! (is-ok (stx-transfer? transfer-coll (as-contract tx-sender) tx-sender))
                  ERR-INSUFFICIENT)
        
        ;; Transfer penalty to protocol owner
        (if (> penalty u0)
            (begin
              (asserts! (is-ok (stx-transfer? penalty (as-contract tx-sender) (var-get owner)))
                       ERR-INSUFFICIENT)
              (ok { liquidated: transfer-coll, penalty: penalty }))
            (ok { liquidated: transfer-coll, penalty: penalty }))))))

;; ----------------- Token Transfer (minimal) -----------------
(define-public (transfer (amount uint) (sender principal) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender sender) ERR-UNAUTHORIZED) ;; Only sender can transfer their own tokens
    (asserts! (not (is-eq sender recipient)) ERR-BAD-ARGS) ;; Can't transfer to self
    (let ((sender-bal (default-to u0 (get amount (map-get? balances { who: sender }))))
          (rec-bal (default-to u0 (get amount (map-get? balances { who: recipient })))))
      (begin
        (asserts! (>= sender-bal amount) ERR-INSUFFICIENT)
        (map-set balances { who: sender } { amount: (- sender-bal amount) })
        (map-set balances { who: recipient } { amount: (+ rec-bal amount) })
        (ok true)))))

;; ----------------- Views for vaults -----------------
(define-read-only (get-vault (who principal))
  (match (map-get? vaults { owner: who })
    v v
    { collateral: u0, debt: u0 }))

(define-read-only (vault-health (who principal))
  (let ((v (default-to { collateral: u0, debt: u0 } (map-get? vaults { owner: who }))))
    (ok (collateralization-bps (get collateral v) (get debt v)))))

;; ----------------- Initialization helper (optional) -----------------
(define-public (init (oracle-principal principal))
  (begin
    (asserts! (is-eq tx-sender (var-get owner)) ERR-UNAUTHORIZED)
    (asserts! (not (is-eq oracle-principal (var-get oracle))) ERR-BAD-ARGS) ;; Only change if different
    (var-set oracle oracle-principal)
    (ok true)))
