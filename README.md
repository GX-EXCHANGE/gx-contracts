# GX Exchange — Smart Contracts

On-chain smart contracts for the GX Exchange platform on Arbitrum.

## Contracts

| Contract | Description |
|---|---|
| `GXVault.sol` | Deposit/withdrawal vault on Arbitrum — handles USDC bridging, fee collection, and vault management |
| `GXStablecoin.sol` | GX stablecoin contract |
| `GXToken.sol` | GX Token (ERC-20) — 1B supply, burnable, permit-enabled |

## Reference

`reference/hyperliquid-bridge/` — Hyperliquid's Bridge2.sol and Signature.sol for reference (originally forked, Apache 2.0 / MIT licensed).

## Setup

```bash
npm install
cp .env.example .env  # add your private key + RPC URLs
npx hardhat compile
npx hardhat test
```

## Deploy

```bash
npx hardhat run scripts/deploy-vault.ts --network arbitrum
```

## License

MIT
