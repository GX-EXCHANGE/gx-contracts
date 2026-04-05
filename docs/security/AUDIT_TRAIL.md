# GX Exchange — Smart Contract Security Audit Trail

## GXVault.sol

### Reference Audits
This contract was reviewed against findings from:
- Zellic Security Assessment of Hyperliquid Bridge2.sol (August 2023)
- Zellic Smart Contract Patch Review of Hyperliquid (December 2023)

Both reports are publicly available at zellic.io.
GXVault.sol shares architectural patterns with Bridge2.sol
(EIP-712 signatures, validator sets, withdrawal queues, dispute periods).

### Findings Applied

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| FIX-1 | HIGH | Nested nonReentrant causes withdrawal DoS | Fixed |
| FIX-2 | MEDIUM | Pending ops survive pause + validator rotation | Fixed |
| FIX-3 | INFO | No message validation before finalization | Fixed |
| FIX-4 | INFO | Domain separator missing address(this) | Fixed |
| FIX-5 | INFO | No action prefix in signed messages | Fixed |
| FIX-6 | INFO | Unchecked transferFrom return value | Fixed |
| FIX-7 | INFO | Wrong block number on Arbitrum (block.number vs ArbSys) | Fixed |
| FIX-8 | INFO | Validator threshold allows exact 2/3 (not strict supermajority) | Fixed |
| FIX-9 | INFO | Events emitted before external calls | Fixed |

### Test Coverage
Run date: March 31, 2026
Solc: 0.8.24
OpenZeppelin: v5.6.1

| Metric | Target | Result |
|--------|--------|--------|
| Lines | >90% | 96.80% |
| Statements | >90% | 96.03% |
| Branches | >80% | 87.88% |
| Functions | >90% | 95.45% |

Total tests: 53 (all passing)

### Remaining Contracts
- [ ] GXStablecoin.sol — pending audit
- [ ] GXLendPool.sol — pending audit
- [ ] GXSwapRouter.sol — pending audit
- [ ] GXYieldVault.sol — pending audit
- [ ] GXStake.sol — pending audit

### External Audit
A formal third-party audit by Zellic, Trail of Bits,
or equivalent is planned before mainnet launch
with significant TVL.
