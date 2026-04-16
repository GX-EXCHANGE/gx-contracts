// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title GXTimelock
 * @author GX Exchange
 * @notice Timelock controller for GX governance. All governance-approved proposals
 *         must wait a minimum delay before execution, giving users time to react.
 *
 * @dev Immutable wrapper around OpenZeppelin's TimelockController.
 *
 *      Configuration (set once at deployment, never changeable):
 *        - Minimum delay: 48 hours (172800 seconds)
 *        - Proposers: [GXGovernor] — only the governor can schedule operations
 *        - Executors: [address(0)] — anyone can execute after the delay expires
 *        - Admin: address(0) — no privileged admin, fully decentralized
 *
 *      The timelock itself retains DEFAULT_ADMIN_ROLE for self-administration
 *      (e.g., updating delay via governance proposal routed through itself).
 */
contract GXTimelock is TimelockController {
    /// @notice 48-hour minimum delay for all governance operations.
    uint256 public constant MIN_TIMELOCK_DELAY = 48 hours;

    /**
     * @notice Deploy the GX governance timelock.
     * @param proposers Array of addresses allowed to propose (should be [GXGovernor]).
     * @param executors Array of addresses allowed to execute. Pass [address(0)] to allow anyone.
     */
    constructor(
        address[] memory proposers,
        address[] memory executors
    )
        TimelockController(
            MIN_TIMELOCK_DELAY, // 48 hours
            proposers,          // [GXGovernor]
            executors,          // [address(0)] = anyone
            address(0)          // no admin — fully decentralized
        )
    {}
}
