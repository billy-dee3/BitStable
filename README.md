# BitStable: STX-Collateralized Stablecoin (sUSD)

A decentralized stablecoin implementation in Clarity v2 that allows users to mint sUSD tokens backed by STX collateral.

## Overview

BitStable is a collateralized debt position (CDP) protocol that enables users to lock up STX as collateral to mint sUSD, a USD-pegged stablecoin. The system maintains stability through over-collateralization and liquidation mechanisms.

## Key Features

- 📌 Mint sUSD tokens backed by STX collateral
- 🔒 Minimum collateralization ratio of 150%
- 💱 Dynamic liquidation system
- 🎯 Oracle price feed integration
- 🔄 SIP-010 compatible token transfers
- 👑 Admin controls for oracle management

## Technical Details

- **Price Scaling**: 6 decimal places (PRICE_SCALE = 1,000,000)
- **Collateral Ratio**: 150% minimum (15,000 basis points)
- **Liquidation Penalty**: 10% (1,000 basis points)
- **Token Decimals**: 6

## Functions

### Vault Management
- `deposit-collateral`: Deposit STX as collateral
- `withdraw-collateral`: Withdraw STX if vault remains healthy
- `mint`: Create new sUSD tokens against collateral
- `repay`: Burn sUSD to reduce debt

### Liquidation
- `liquidate`: Liquidate unhealthy vaults (< 150% collateral ratio)
- Liquidators receive discounted collateral plus penalty

### Token Operations
- `transfer`: Standard SIP-010 token transfer
- `get-balance`: Check sUSD balance
- `get-total-supply`: Get total sUSD in circulation

## Security Features

- ✅ Safe arithmetic operations
- ✅ Comprehensive input validation
- ✅ Access control checks
- ✅ Reentrancy protection
- ✅ Proper error handling

## Installation

```bash
clarinet contract publish BitStable.clar
```

## Usage

```clarity
;; Deposit collateral
(contract-call? .bitstable deposit-collateral u1000000)

;; Mint sUSD
(contract-call? .bitstable mint u500000)
```

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## License

[MIT](https://choosealicense.com/licenses/mit/)

## Disclaimer

This code is provided as-is. Use at your own risk. Always audit smart contracts before deployment.

---
