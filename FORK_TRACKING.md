# GX Exchange — Smart Contract Fork Tracking

## ALL CONTRACTS ARE IMMUTABLE — No proxy, no upgrade, no admin keys.

---

## Phase 1 — Launch (BUILT)

| GX Contract | Forked From | Original Location | Lines | Status |
|-------------|-------------|-------------------|-------|--------|
| **GXToken.sol** | OpenZeppelin ERC20+Permit+Burnable | @openzeppelin/contracts | 558 | BUILT |
| **GXStaking.sol** | Synthetix StakingRewards | `forked-originals/SynthetixStakingRewards.sol.original` | 16,789 | BUILT |
| **GXFeeDistributor.sol** | Curve FeeDistributor (Solidity rewrite) | N/A (clean-room from Vyper) | 11,980 | BUILT |
| **GXBridge.sol** | Gravity Bridge | `forked-originals/GravityBridge.sol.original` | 23,980 | BUILT |
| **GXveToken.sol** | Curve VotingEscrow (Solidity port) | `forked-originals/SperaxVeToken.sol` (ref) | 22,504 | BUILT |
| **GXGovernor.sol** | OpenZeppelin Governor suite | @openzeppelin/contracts | 5,880 | BUILT |
| **GXTimelock.sol** | OpenZeppelin TimelockController | @openzeppelin/contracts | 1,722 | BUILT |
| **GXAirdrop.sol** | Uniswap MerkleDistributor | `forked-originals/UniswapMerkleDistributor.sol.original` | 8,940 | BUILT |
| **GXVesting.sol** | OpenZeppelin VestingWallet | @openzeppelin/contracts | 9,769 | BUILT |

## Phase 2 — Months 1-3 (TO BUILD)

| GX Contract | Fork From | CertiK Score | Status |
|-------------|-----------|-------------|--------|
| **GXUSD.sol** | Liquity V1 (BorrowerOps + TroveManager + StabilityPool) | 78.33 BBB | TO DO |
| **GXLending.sol** | Aave V3 / Compound V3 | 94.48 AAA | TO DO |
| **GXSwapRouter.sol** | Uniswap V3 | 95.18 AAA | TO DO |
| **GXStableSwap.sol** | Curve StableSwap (Solidity port) | 91.62 AA | TO DO |
| **GXYieldVault.sol** | OpenZeppelin ERC4626 + Yearn V3 | N/A | TO DO |
| **GXInsurance.sol** | Liquity StabilityPool | 78.33 BBB | TO DO |

## Phase 3 — Months 4-6+ (TO BUILD)

| GX Contract | Fork From | CertiK Score | Status |
|-------------|-----------|-------------|--------|
| **GXIndexV2.sol** | Set Protocol V2 BasicIssuanceModule | N/A (8+ audits) | TO DO |
| **GXPrediction.sol** | Gnosis CTF + Polymarket | N/A (ChainSecurity) | TO DO |
| **GXBotSubscription.sol** | Custom (OpenZeppelin base) | N/A | TO DO |
| **GXSignalSubscription.sol** | Custom (OpenZeppelin base) | N/A | TO DO |

## Legacy Contracts (TO BE REPLACED)

These were built before the fork strategy. They will be replaced by the forked versions above:

| Legacy Contract | Replace With | Why |
|----------------|-------------|-----|
| GXVault.sol (old bridge) | GXBridge.sol | 3 Critical vulns found in audit |
| GXVaultV2.sol (old bridge) | GXBridge.sol | Same issues |
| GXIndex.sol (old) | GXIndexV2.sol (Phase 3) | Empty buy/sell functions, NAV manipulation |
| GXIndexFactory.sol (old) | GXIndexV2.sol (Phase 3) | Depends on broken GXIndex |
| GXStablecoin.sol (old) | GXUSD.sol (Phase 2) | No pause, no vault validation |

## Forked Originals Reference

All original source contracts saved in `contracts/forked-originals/`:

| File | Source | License |
|------|--------|---------|
| SynthetixStakingRewards.sol.original | github.com/Synthetixio/synthetix | MIT |
| GravityBridge.sol.original | github.com/Gravity-Bridge/Gravity-Bridge | Apache-2.0 |
| UniswapMerkleDistributor.sol.original | github.com/Uniswap/merkle-distributor | GPL-3.0 |
| SperaxVeToken.sol | Reference notes (repo 404) | MIT |

## Deployment Decision

**Deployment is controlled by Shah (CEO). No contract will be deployed without explicit approval.**

Pre-deployment checklist per contract:
- [ ] Internal code review
- [ ] External audit ($30K)
- [ ] 30-day testnet deployment
- [ ] Bug bounty live
- [ ] Shah approves deployment
