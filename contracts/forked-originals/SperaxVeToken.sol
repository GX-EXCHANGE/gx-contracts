// SPDX-License-Identifier: MIT
// NOTE: The original Sperax VeToken Solidity port
// (https://github.com/nicedavid98/Vote-Escrow-Smart-Contract-Template/main/contracts/VeToken.sol)
// was unavailable (404) at the time of forking (2026-04-09).
//
// GXveToken.sol was written from scratch as a clean-room Solidity 0.8.24 implementation
// of the Curve Finance VotingEscrow (vyper) design:
//   - Lock ERC-20 tokens for 1-4 years
//   - Linear decay of voting power over time
//   - Non-transferable (soulbound)
//   - create_lock / increase_amount / increase_unlock_time / withdraw
//
// Reference contracts studied:
//   - Curve VotingEscrow.vy (original Vyper)
//   - Sperax USDs VeToken (Solidity port, no longer available)
//   - Angle Protocol veANGLE
//   - Frax Finance veFXS
//
// This file is kept as a placeholder in forked-originals/ per project convention.

pragma solidity ^0.8.24;
// No code — original source was unavailable.
