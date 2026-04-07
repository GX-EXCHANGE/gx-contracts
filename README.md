# GX Exchange Smart Contracts

On-chain smart contracts powering the GX Exchange platform's bridge and token infrastructure on Arbitrum.

## Contracts

| Contract | Description |
|---|---|
| GXVault.sol | Deposit and withdrawal vault on Arbitrum — handles USDC bridging, fee collection, and vault management |
| GXStablecoin.sol | GX stablecoin contract |
| GXToken.sol | GX Token (ERC-20) — 1 billion fixed supply, burnable, permit-enabled |

## Overview

These contracts form the bridge layer between Arbitrum and GX Chain, enabling users to deposit and withdraw assets securely. The vault contract manages USDC custody with multi-validator quorum verification and timelock protections.

## Requirements

- Node.js 18+
- Hardhat

## License

MIT
