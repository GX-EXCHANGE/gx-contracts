// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title GXGovernor
 * @author GX Exchange
 * @notice On-chain governance for the GX protocol. Token holders (via veGX voting
 *         escrow) can propose and vote on protocol changes. Approved proposals are
 *         executed through {GXTimelock} after a mandatory delay.
 *
 * @dev Immutable — no proxy pattern, no admin upgrade path.
 *
 *      Composed from OpenZeppelin Governor modules:
 *        - Governor (base)
 *        - GovernorVotes (vote weight sourced from veGX / IVotes token)
 *        - GovernorVotesQuorumFraction (1% of total supply required for quorum)
 *        - GovernorTimelockControl (execution routed through GXTimelock)
 *        - GovernorCountingSimple (For / Against / Abstain)
 *
 *      All governance parameters are set in the constructor and cannot be changed:
 *        - Voting delay:       1 day  (~7,200 blocks at 12s/block)
 *        - Voting period:      5 days (~36,000 blocks at 12s/block)
 *        - Proposal threshold: 100,000 GX (must hold to create a proposal)
 *        - Quorum:             1% of total supply at snapshot block
 */
contract GXGovernor is
    Governor,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    GovernorCountingSimple
{
    // ---------------------------------------------------------------
    //  Constants — governance parameters (immutable after deployment)
    // ---------------------------------------------------------------

    /// @notice Delay between proposal creation and voting start (~1 day).
    uint48 private constant VOTING_DELAY = 7_200;

    /// @notice Duration of the voting window (~5 days).
    uint32 private constant VOTING_PERIOD = 36_000;

    /// @notice Minimum veGX balance required to create a proposal (10,000 GX = $800).
    uint256 private constant PROPOSAL_THRESHOLD = 10_000 * 1e18;

    /// @notice Quorum expressed as a percentage of total veGX supply (1%).
    uint256 private constant QUORUM_PERCENT = 1;

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    /**
     * @notice Deploy the GX Governor.
     * @param _token The veGX (or GX) token implementing IVotes for vote-weight snapshots.
     * @param _timelock The GXTimelock contract that executes approved proposals.
     */
    constructor(
        IVotes _token,
        TimelockController _timelock
    )
        Governor("GXGovernor")
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(QUORUM_PERCENT)
        GovernorTimelockControl(_timelock)
    {}

    // ---------------------------------------------------------------
    //  Required overrides — Governor parameter getters
    // ---------------------------------------------------------------

    /// @inheritdoc Governor
    function votingDelay() public pure override returns (uint256) {
        return VOTING_DELAY;
    }

    /// @inheritdoc Governor
    function votingPeriod() public pure override returns (uint256) {
        return VOTING_PERIOD;
    }

    /// @inheritdoc Governor
    function proposalThreshold() public pure override returns (uint256) {
        return PROPOSAL_THRESHOLD;
    }

    // ---------------------------------------------------------------
    //  Required overrides — resolve diamond inheritance
    // ---------------------------------------------------------------

    /// @inheritdoc Governor
    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /// @inheritdoc Governor
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /// @inheritdoc Governor
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(Governor, GovernorTimelockControl)
        returns (uint48)
    {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(Governor, GovernorTimelockControl)
    {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    )
        internal
        override(Governor, GovernorTimelockControl)
        returns (uint256)
    {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @inheritdoc Governor
    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
}
