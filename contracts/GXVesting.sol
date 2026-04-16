// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title GXVesting
 * @author GX Exchange
 * @notice Linear vesting contract with cliff for a single beneficiary.
 *         Based on the OpenZeppelin VestingWallet pattern.
 *
 *         Deploy one instance per beneficiary with the desired schedule:
 *           - Team members:  1-year cliff, 3-year total vest
 *           - Investors:     6-month cliff, 2-year total vest
 *
 *         IMMUTABLE — no proxy, no admin upgrade, no owner.
 *         The vesting schedule is locked at deployment and cannot be modified.
 *
 * @dev After deployment, transfer the full `totalAllocation` of `token` to this contract.
 *      The beneficiary calls `release()` at any time to claim all currently vested tokens.
 *      Vesting math:
 *        - Before cliff:  0 vested
 *        - At cliff:      (cliffDuration / vestingDuration) * totalAllocation
 *        - After cliff:   linear interpolation up to totalAllocation at vestingEnd
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Custom errors
// ──────────────────────────────────────────────────────────────────────────────
error ZeroAddress();
error ZeroAmount();
error InvalidDurations();
error NothingToRelease();

contract GXVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    // Immutable state
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice The beneficiary who receives vested tokens.
    address public immutable beneficiary;

    /// @notice The ERC-20 token being vested.
    address public immutable token;

    /// @notice Total number of tokens to vest over the full schedule.
    uint256 public immutable totalAllocation;

    /// @notice Timestamp when the vesting schedule starts (deployment time).
    uint256 public immutable vestingStart;

    /// @notice Duration of the cliff period in seconds.
    uint256 public immutable cliffDuration;

    /// @notice Total duration of the vesting schedule in seconds (includes cliff).
    uint256 public immutable vestingDuration;

    /// @notice Timestamp when the cliff ends and the first tokens become claimable.
    uint256 public immutable cliffEnd;

    /// @notice Timestamp when 100 % of tokens are vested.
    uint256 public immutable vestingEnd;

    // ──────────────────────────────────────────────────────────────────────────
    // Mutable state
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Total amount of tokens already released to the beneficiary.
    uint256 public released;

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Emitted each time the beneficiary claims vested tokens.
    event TokensReleased(address indexed beneficiary, uint256 amount);

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @param _beneficiary     Address that will receive vested tokens.
     * @param _token           ERC-20 token address.
     * @param _totalAllocation Total tokens to be vested (must be deposited after deploy).
     * @param _cliffDuration   Cliff period in seconds (e.g. 365 days for team).
     * @param _vestingDuration Total vest duration in seconds including cliff (e.g. 3 * 365 days).
     */
    constructor(
        address _beneficiary,
        address _token,
        uint256 _totalAllocation,
        uint256 _cliffDuration,
        uint256 _vestingDuration
    ) {
        if (_beneficiary == address(0)) revert ZeroAddress();
        if (_token == address(0)) revert ZeroAddress();
        if (_totalAllocation == 0) revert ZeroAmount();
        if (_vestingDuration == 0) revert InvalidDurations();
        if (_cliffDuration >= _vestingDuration) revert InvalidDurations();

        beneficiary = _beneficiary;
        token = _token;
        totalAllocation = _totalAllocation;
        cliffDuration = _cliffDuration;
        vestingDuration = _vestingDuration;

        vestingStart = block.timestamp;
        cliffEnd = block.timestamp + _cliffDuration;
        vestingEnd = block.timestamp + _vestingDuration;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Release
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Release all currently vested (and unreleased) tokens to the beneficiary.
     *         Can be called by anyone, but tokens always go to the beneficiary.
     */
    function release() external nonReentrant {
        uint256 vested = vestedAmount();
        uint256 releasable = vested - released;
        if (releasable == 0) revert NothingToRelease();

        released = vested;
        IERC20(token).safeTransfer(beneficiary, releasable);

        emit TokensReleased(beneficiary, releasable);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // View helpers
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Calculate the total amount of tokens vested up to the current block timestamp.
     * @return The cumulative vested amount (may exceed `released`).
     */
    function vestedAmount() public view returns (uint256) {
        return _vestingSchedule(block.timestamp);
    }

    /**
     * @notice Amount of tokens that can be released right now.
     * @return The releasable amount.
     */
    function releasable() external view returns (uint256) {
        uint256 vested = vestedAmount();
        return vested > released ? vested - released : 0;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @dev Core vesting formula.
     *      - Before cliffEnd: 0
     *      - Between cliffEnd and vestingEnd: linear from 0 → totalAllocation
     *        (proportional to elapsed time since vestingStart / vestingDuration)
     *      - After vestingEnd: totalAllocation
     * @param _timestamp The point in time to evaluate.
     * @return The cumulative vested amount at `_timestamp`.
     */
    function _vestingSchedule(uint256 _timestamp) private view returns (uint256) {
        if (_timestamp < cliffEnd) {
            return 0;
        } else if (_timestamp >= vestingEnd) {
            return totalAllocation;
        } else {
            // Linear: totalAllocation * elapsed / vestingDuration
            // elapsed is measured from vestingStart (not cliffEnd) so the cliff
            // unlocks proportionally, matching standard linear-with-cliff schedules.
            uint256 elapsed = _timestamp - vestingStart;
            return (totalAllocation * elapsed) / vestingDuration;
        }
    }
}
