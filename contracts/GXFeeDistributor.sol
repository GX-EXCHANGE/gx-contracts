// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GXFeeDistributor
 * @author GX Exchange — inspired by Curve Finance FeeDistributor pattern
 * @notice Receives all protocol fees and distributes them on a weekly epoch
 *         basis with hardcoded, immutable split ratios:
 *
 *           40% — GXStaking (staker rewards)
 *           20% — Burn address (buy & burn GX)
 *           20% — Insurance fund
 *           20% — Treasury
 *
 * @dev IMMUTABLE — split ratios cannot be changed after deployment.
 *      Anyone can call `distribute()` (permissionless).
 *      Uses a checkpoint system so each epoch's balance is snapshotted
 *      and distributed exactly once.
 */
contract GXFeeDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ======================================================================
       CONSTANTS (IMMUTABLE POLICY)
       ====================================================================== */

    /// @notice Split ratios in basis points (total = 10,000 = 100%).
    uint256 public constant STAKERS_BPS    = 4000; // 40%
    uint256 public constant BURN_BPS       = 2000; // 20%
    uint256 public constant INSURANCE_BPS  = 2000; // 20%
    uint256 public constant TREASURY_BPS   = 2000; // 20%

    /// @notice Epoch length — distributions happen at most once per week.
    uint256 public constant EPOCH_DURATION = 1 weeks;

    /// @notice Canonical burn address (tokens sent here are irrecoverable).
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /* ======================================================================
       IMMUTABLE STATE (set once in constructor)
       ====================================================================== */

    /// @notice The fee token distributed (e.g. USDC).
    IERC20 public immutable feeToken;

    /// @notice GXStaking contract — receives staker share.
    address public immutable stakingContract;

    /// @notice Insurance fund multisig/contract.
    address public immutable insuranceFund;

    /// @notice Treasury multisig/contract.
    address public immutable treasury;

    /// @notice Timestamp of the first epoch start (rounded down to week).
    uint256 public immutable startTime;

    /* ======================================================================
       STORAGE
       ====================================================================== */

    /// @notice Epoch start timestamp => total fee tokens checkpointed for that epoch.
    mapping(uint256 => uint256) public epochFees;

    /// @notice Epoch start timestamp => whether distribution has been executed.
    mapping(uint256 => bool) public epochDistributed;

    /// @notice Tracks the last time fees were checkpointed, to compute deltas.
    uint256 public lastCheckpointBalance;

    /// @notice The latest epoch that has been checkpointed.
    uint256 public lastCheckpointEpoch;

    /// @notice Running total of all fees ever distributed.
    uint256 public totalDistributed;

    /* ======================================================================
       EVENTS
       ====================================================================== */

    event Checkpointed(uint256 indexed epoch, uint256 amount);
    event Distributed(
        uint256 indexed epoch,
        uint256 toStakers,
        uint256 toBurn,
        uint256 toInsurance,
        uint256 toTreasury
    );
    event FeeReceived(address indexed from, uint256 amount);

    /* ======================================================================
       ERRORS
       ====================================================================== */

    error EpochNotFinished(uint256 epochEnd);
    error EpochAlreadyDistributed(uint256 epoch);
    error NoFeesToDistribute(uint256 epoch);
    error ZeroAddress();

    /* ======================================================================
       CONSTRUCTOR
       ====================================================================== */

    /**
     * @param _feeToken         The ERC-20 token in which fees are denominated (e.g. USDC).
     * @param _stakingContract  Address of the GXStaking contract.
     * @param _insuranceFund    Address of the insurance fund.
     * @param _treasury         Address of the treasury.
     */
    constructor(
        address _feeToken,
        address _stakingContract,
        address _insuranceFund,
        address _treasury
    ) {
        if (_feeToken == address(0)) revert ZeroAddress();
        if (_stakingContract == address(0)) revert ZeroAddress();
        if (_insuranceFund == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        feeToken = IERC20(_feeToken);
        stakingContract = _stakingContract;
        insuranceFund = _insuranceFund;
        treasury = _treasury;

        // Round down to the start of the current week
        startTime = (block.timestamp / EPOCH_DURATION) * EPOCH_DURATION;
        lastCheckpointEpoch = startTime;
    }

    /* ======================================================================
       VIEW FUNCTIONS
       ====================================================================== */

    /// @notice Returns the start timestamp of the current epoch.
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp / EPOCH_DURATION) * EPOCH_DURATION;
    }

    /// @notice Returns the start timestamp of the next distributable epoch.
    function nextDistributableEpoch() external view returns (uint256) {
        uint256 epoch = lastCheckpointEpoch;
        // Find the first un-distributed epoch that has ended
        while (epoch < currentEpoch()) {
            if (!epochDistributed[epoch] && epochFees[epoch] > 0) {
                return epoch;
            }
            epoch += EPOCH_DURATION;
        }
        return currentEpoch() + EPOCH_DURATION; // next future epoch
    }

    /// @notice Preview how much each recipient would get for a given fee amount.
    function previewSplit(uint256 amount)
        external
        pure
        returns (
            uint256 toStakers,
            uint256 toBurn,
            uint256 toInsurance,
            uint256 toTreasury
        )
    {
        toStakers  = (amount * STAKERS_BPS) / 10_000;
        toBurn     = (amount * BURN_BPS) / 10_000;
        toInsurance = (amount * INSURANCE_BPS) / 10_000;
        toTreasury = amount - toStakers - toBurn - toInsurance; // absorbs rounding dust
    }

    /// @notice Total undistributed fees sitting in the contract.
    function pendingFees() external view returns (uint256) {
        return feeToken.balanceOf(address(this));
    }

    /* ======================================================================
       CHECKPOINT — SNAPSHOT FEES INTO EPOCHS
       ====================================================================== */

    /**
     * @notice Checkpoint: record any new fee tokens received since last
     *         checkpoint into the current (or most recent completed) epoch.
     *         Anyone can call this.
     */
    function checkpoint() public {
        uint256 currentBal = feeToken.balanceOf(address(this));
        uint256 newFees = currentBal - lastCheckpointBalance;

        if (newFees == 0) return;

        uint256 epoch = currentEpoch();
        epochFees[epoch] += newFees;
        lastCheckpointBalance = currentBal;
        lastCheckpointEpoch = epoch;

        emit Checkpointed(epoch, newFees);
    }

    /* ======================================================================
       DISTRIBUTION — PERMISSIONLESS
       ====================================================================== */

    /**
     * @notice Distribute fees for a completed epoch. Anyone can call.
     * @param epoch The epoch start timestamp to distribute. Must be in the past.
     */
    function distribute(uint256 epoch) external nonReentrant {
        // Checkpoint first to capture any unrecorded fees
        checkpoint();

        // Epoch must be finished
        if (epoch + EPOCH_DURATION > block.timestamp) {
            revert EpochNotFinished(epoch + EPOCH_DURATION);
        }

        // Cannot distribute twice
        if (epochDistributed[epoch]) {
            revert EpochAlreadyDistributed(epoch);
        }

        uint256 amount = epochFees[epoch];
        if (amount == 0) revert NoFeesToDistribute(epoch);

        epochDistributed[epoch] = true;
        totalDistributed += amount;

        // Calculate splits
        uint256 toStakers   = (amount * STAKERS_BPS) / 10_000;
        uint256 toBurn      = (amount * BURN_BPS) / 10_000;
        uint256 toInsurance  = (amount * INSURANCE_BPS) / 10_000;
        uint256 toTreasury   = amount - toStakers - toBurn - toInsurance; // dust goes to treasury

        // Update checkpoint balance before transfers
        lastCheckpointBalance -= amount;

        // Execute transfers
        feeToken.safeTransfer(stakingContract, toStakers);
        feeToken.safeTransfer(BURN_ADDRESS, toBurn);
        feeToken.safeTransfer(insuranceFund, toInsurance);
        feeToken.safeTransfer(treasury, toTreasury);

        emit Distributed(epoch, toStakers, toBurn, toInsurance, toTreasury);
    }

    /**
     * @notice Distribute all completed, undistributed epochs in one call.
     *         Gas-bounded: processes at most `maxEpochs` to avoid block limit.
     * @param maxEpochs Maximum number of epochs to process.
     * @return processed Number of epochs actually distributed.
     */
    function distributeMany(uint256 maxEpochs) external nonReentrant returns (uint256 processed) {
        checkpoint();

        uint256 epoch = startTime;
        uint256 current = currentEpoch();

        while (epoch < current && processed < maxEpochs) {
            if (!epochDistributed[epoch] && epochFees[epoch] > 0) {
                uint256 amount = epochFees[epoch];
                epochDistributed[epoch] = true;
                totalDistributed += amount;

                uint256 toStakers   = (amount * STAKERS_BPS) / 10_000;
                uint256 toBurn      = (amount * BURN_BPS) / 10_000;
                uint256 toInsurance  = (amount * INSURANCE_BPS) / 10_000;
                uint256 toTreasury   = amount - toStakers - toBurn - toInsurance;

                lastCheckpointBalance -= amount;

                feeToken.safeTransfer(stakingContract, toStakers);
                feeToken.safeTransfer(BURN_ADDRESS, toBurn);
                feeToken.safeTransfer(insuranceFund, toInsurance);
                feeToken.safeTransfer(treasury, toTreasury);

                emit Distributed(epoch, toStakers, toBurn, toInsurance, toTreasury);
                processed++;
            }
            epoch += EPOCH_DURATION;
        }
    }

    /* ======================================================================
       CONVENIENCE — DEPOSIT FEES
       ====================================================================== */

    /**
     * @notice Convenience function for protocol contracts to deposit fees.
     *         Pulls `amount` of feeToken from msg.sender and auto-checkpoints.
     * @param amount Amount of fee tokens to deposit.
     */
    function depositFees(uint256 amount) external nonReentrant {
        feeToken.safeTransferFrom(msg.sender, address(this), amount);

        // Immediately checkpoint so the deposit is attributed to current epoch
        uint256 epoch = currentEpoch();
        epochFees[epoch] += amount;
        lastCheckpointBalance += amount;

        if (epoch > lastCheckpointEpoch) {
            lastCheckpointEpoch = epoch;
        }

        emit FeeReceived(msg.sender, amount);
        emit Checkpointed(epoch, amount);
    }
}
