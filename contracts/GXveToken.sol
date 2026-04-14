// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/interfaces/IERC5805.sol";
import "@openzeppelin/contracts/interfaces/IERC6372.sol";

/**
 * @title GXveToken (veGX)
 * @author GX Exchange
 * @notice Vote-escrowed GX token — a Solidity port of the Curve Finance VotingEscrow
 *         design. Users lock GX tokens for 1–4 years and receive non-transferable veGX
 *         voting power that decays linearly toward zero at the unlock time.
 *
 * @dev Immutable contract — no proxy, no owner, no admin upgrade.
 *
 *      Core mechanics:
 *        - 1 GX locked for 4 years = 1 veGX (maximum voting power)
 *        - Voting power decays linearly: balance = locked_amount * (time_remaining / MAXTIME)
 *        - Locks are quantised to whole weeks to reduce storage writes
 *        - Non-transferable (soulbound) — no transfer/approve functions
 *        - Implements IVotes + IERC5805 + IERC6372 for Governor compatibility
 *
 *      Supported operations:
 *        - create_lock(amount, unlock_time) — deposit GX and start a lock
 *        - increase_amount(amount)          — add more GX to an existing lock
 *        - increase_unlock_time(new_time)   — extend the lock duration
 *        - withdraw()                       — reclaim GX after lock expires
 *
 *      Checkpoint system (Curve-style):
 *        - Per-user and global "Point" snapshots record bias + slope at each change
 *        - slope_changes[] track when global slope decreases (as locks expire)
 *        - Enables efficient historical balance lookups for governance snapshots
 */
contract GXveToken is ReentrancyGuard, IERC5805 {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //  Constants
    // ---------------------------------------------------------------

    /// @notice Maximum lock duration: 4 years (in seconds).
    uint256 public constant MAXTIME = 4 * 365 * 86400; // 126,144,000 seconds

    /// @notice Minimum lock duration: 7 days (in seconds).
    uint256 public constant MINTIME = 7 * 86400;

    /// @notice Locks are rounded down to the nearest week.
    uint256 public constant WEEK = 7 * 86400;

    // ---------------------------------------------------------------
    //  Types
    // ---------------------------------------------------------------

    /// @dev A checkpoint recording voting-power slope and bias at a point in time.
    struct Point {
        int128 bias;       // veGX balance at the recorded time
        int128 slope;      // rate of decay: -locked_amount / MAXTIME per second
        uint256 ts;        // timestamp of the checkpoint
        uint256 blk;       // block number of the checkpoint
    }

    /// @dev Per-user lock state.
    struct LockedBalance {
        int128 amount;     // locked GX amount (signed for arithmetic convenience)
        uint256 end;       // unlock timestamp (week-aligned)
    }

    // ---------------------------------------------------------------
    //  State
    // ---------------------------------------------------------------

    /// @notice The GX ERC-20 token being locked.
    IERC20 public immutable token;

    /// @notice Total GX currently locked in the contract.
    uint256 public supply;

    /// @notice Per-user lock data.
    mapping(address => LockedBalance) public locked;

    /// @notice Global epoch counter (incremented on each global checkpoint).
    uint256 public epoch;

    /// @notice Global point history — point_history[epoch] = Point.
    mapping(uint256 => Point) public pointHistory;

    /// @notice Per-user epoch counter.
    mapping(address => uint256) public userPointEpoch;

    /// @notice Per-user point history — user_point_history[addr][epoch] = Point.
    mapping(address => mapping(uint256 => Point)) public userPointHistory;

    /// @notice Scheduled slope changes — slope_changes[timestamp] = delta slope.
    mapping(uint256 => int128) public slopeChanges;

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    /// @notice Emitted when a user creates or modifies a lock.
    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 indexed locktime,
        uint256 ts
    );

    /// @notice Emitted when a user withdraws after lock expiry.
    event Withdraw(address indexed provider, uint256 value, uint256 ts);

    /// @notice Emitted when total supply changes.
    event Supply(uint256 prevSupply, uint256 supply);

    // ---------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------

    error LockNotFound();
    error LockNotExpired();
    error LockAlreadyExists();
    error LockExpired();
    error ZeroAmount();
    error UnlockTimeTooShort();
    error UnlockTimeTooLong();
    error UnlockTimeNotFuture();
    error CanOnlyExtendLock();
    error NonTransferable();

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    /**
     * @notice Deploy the veGX token.
     * @param _token Address of the GX ERC-20 token to lock.
     */
    constructor(IERC20 _token) {
        token = _token;

        // Initialise the global point history at epoch 0.
        pointHistory[0] = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
    }

    // ---------------------------------------------------------------
    //  ERC-20 metadata (read-only, non-transferable)
    // ---------------------------------------------------------------

    /// @notice Token name.
    function name() external pure returns (string memory) {
        return "Vote-Escrowed GX";
    }

    /// @notice Token symbol.
    function symbol() external pure returns (string memory) {
        return "veGX";
    }

    /// @notice Token decimals (same as GX: 18).
    function decimals() external pure returns (uint8) {
        return 18;
    }

    // ---------------------------------------------------------------
    //  Soulbound — transfers disabled
    // ---------------------------------------------------------------

    /// @notice veGX is non-transferable. Always reverts.
    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice veGX is non-transferable. Always reverts.
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice veGX is non-transferable. Always reverts.
    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Always returns 0.
    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    // ---------------------------------------------------------------
    //  IERC6372 — Clock
    // ---------------------------------------------------------------

    /// @inheritdoc IERC6372
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @inheritdoc IERC6372
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure override returns (string memory) {
        return "mode=timestamp";
    }

    // ---------------------------------------------------------------
    //  Core — Lock Management
    // ---------------------------------------------------------------

    /**
     * @notice Lock GX tokens to receive veGX voting power.
     * @param _value Amount of GX to lock (must be > 0).
     * @param _unlockTime Desired unlock timestamp (will be rounded down to nearest week).
     *                    Must be between MINTIME and MAXTIME from now.
     */
    function create_lock(uint256 _value, uint256 _unlockTime) external nonReentrant {
        if (_value == 0) revert ZeroAmount();

        LockedBalance storage _locked = locked[msg.sender];
        if (_locked.amount > 0) revert LockAlreadyExists();

        uint256 unlockWeek = (_unlockTime / WEEK) * WEEK; // round down to week
        if (unlockWeek <= block.timestamp) revert UnlockTimeNotFuture();
        if (unlockWeek < block.timestamp + MINTIME) revert UnlockTimeTooShort();
        if (unlockWeek > block.timestamp + MAXTIME) revert UnlockTimeTooLong();

        _depositFor(msg.sender, _value, unlockWeek, _locked);
    }

    /**
     * @notice Add more GX to an existing lock (does not change unlock time).
     * @param _value Additional GX to lock.
     */
    function increase_amount(uint256 _value) external nonReentrant {
        if (_value == 0) revert ZeroAmount();

        LockedBalance storage _locked = locked[msg.sender];
        if (_locked.amount <= 0) revert LockNotFound();
        if (_locked.end <= block.timestamp) revert LockExpired();

        _depositFor(msg.sender, _value, 0, _locked);
    }

    /**
     * @notice Extend the unlock time of an existing lock.
     * @param _unlockTime New unlock timestamp (rounded to week). Must be further in the
     *                    future than the current unlock time.
     */
    function increase_unlock_time(uint256 _unlockTime) external nonReentrant {
        LockedBalance storage _locked = locked[msg.sender];
        if (_locked.amount <= 0) revert LockNotFound();
        if (_locked.end <= block.timestamp) revert LockExpired();

        uint256 unlockWeek = (_unlockTime / WEEK) * WEEK;
        if (unlockWeek <= _locked.end) revert CanOnlyExtendLock();
        if (unlockWeek > block.timestamp + MAXTIME) revert UnlockTimeTooLong();

        _depositFor(msg.sender, 0, unlockWeek, _locked);
    }

    /**
     * @notice Withdraw all locked GX after the lock has expired.
     */
    function withdraw() external nonReentrant {
        LockedBalance storage _locked = locked[msg.sender];
        if (_locked.end > block.timestamp) revert LockNotExpired();
        if (_locked.amount <= 0) revert LockNotFound();

        uint256 value = uint256(uint128(_locked.amount));

        LockedBalance memory oldLocked = _locked;
        _locked.amount = 0;
        _locked.end = 0;

        uint256 prevSupply = supply;
        supply -= value;

        // Checkpoint with zeroed-out lock.
        _checkpoint(msg.sender, oldLocked, _locked);

        token.safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(prevSupply, supply);
    }

    // ---------------------------------------------------------------
    //  Core — Internal Deposit
    // ---------------------------------------------------------------

    /**
     * @dev Deposit GX and/or update lock end time. Handles checkpointing.
     * @param _addr User address.
     * @param _value Amount of GX to deposit (0 if only extending time).
     * @param _unlockTime New unlock week (0 if only adding amount).
     * @param _locked Storage pointer to the user's lock.
     */
    function _depositFor(
        address _addr,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance storage _locked
    ) internal {
        uint256 prevSupply = supply;
        supply += _value;

        LockedBalance memory oldLocked = LockedBalance({
            amount: _locked.amount,
            end: _locked.end
        });

        // Update the lock.
        _locked.amount += int128(int256(_value));
        if (_unlockTime != 0) {
            _locked.end = _unlockTime;
        }

        // Write checkpoints.
        _checkpoint(_addr, oldLocked, _locked);

        if (_value != 0) {
            token.safeTransferFrom(_addr, address(this), _value);
        }

        emit Deposit(_addr, _value, _locked.end, block.timestamp);
        emit Supply(prevSupply, supply);
    }

    // ---------------------------------------------------------------
    //  Core — Checkpoint System
    // ---------------------------------------------------------------

    /**
     * @dev Record global and per-user point snapshots. This is the heart of the
     *      vote-escrow accounting — it updates bias, slope, and slope_changes
     *      so that voting power decays correctly over time.
     *
     * @param _addr User address (address(0) for global-only checkpoint).
     * @param _oldLocked Previous lock state.
     * @param _newLocked New lock state.
     */
    function _checkpoint(
        address _addr,
        LockedBalance memory _oldLocked,
        LockedBalance memory _newLocked
    ) internal {
        Point memory uOld;
        Point memory uNew;

        // Calculate old and new user slopes/biases.
        if (_addr != address(0)) {
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                uOld.slope = _oldLocked.amount / int128(int256(MAXTIME));
                uOld.bias = uOld.slope * int128(int256(_oldLocked.end - block.timestamp));
            }
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                uNew.slope = _newLocked.amount / int128(int256(MAXTIME));
                uNew.bias = uNew.slope * int128(int256(_newLocked.end - block.timestamp));
            }
        }

        // --- Global checkpoint: iterate week-by-week from last checkpoint ---
        Point memory lastPoint;
        if (epoch > 0) {
            lastPoint = pointHistory[epoch];
        } else {
            lastPoint = pointHistory[0];
        }
        uint256 lastCheckpoint = lastPoint.ts;
        Point memory initialLastPoint = Point({
            bias: lastPoint.bias,
            slope: lastPoint.slope,
            ts: lastPoint.ts,
            blk: lastPoint.blk
        });
        uint256 blockSlope = 0; // dblock/dt
        if (block.timestamp > lastPoint.ts) {
            blockSlope = (1e18 * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
        }

        // Fill in missing weekly checkpoints.
        uint256 tI = (lastCheckpoint / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; i++) {
            tI += WEEK;
            int128 dSlope = 0;
            if (tI > block.timestamp) {
                tI = block.timestamp;
            } else {
                dSlope = slopeChanges[tI];
            }
            lastPoint.bias -= lastPoint.slope * int128(int256(tI - lastCheckpoint));
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) lastPoint.bias = 0;
            if (lastPoint.slope < 0) lastPoint.slope = 0;
            lastCheckpoint = tI;
            lastPoint.ts = tI;
            lastPoint.blk = initialLastPoint.blk +
                (blockSlope * (tI - initialLastPoint.ts)) / 1e18;
            epoch += 1;
            if (tI == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                pointHistory[epoch] = lastPoint;
            }
        }
        pointHistory[epoch] = lastPoint;

        // --- Adjust slope changes ---
        if (_addr != address(0)) {
            // Remove old slope changes, add new ones.
            if (_oldLocked.end > block.timestamp) {
                int128 oldDSlope = slopeChanges[_oldLocked.end];
                oldDSlope += uOld.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldDSlope -= uNew.slope; // same end: net change
                }
                slopeChanges[_oldLocked.end] = oldDSlope;
            }
            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    slopeChanges[_newLocked.end] -= uNew.slope;
                }
            }

            // Update global point with user slope/bias delta.
            lastPoint.bias += (uNew.bias - uOld.bias);
            lastPoint.slope += (uNew.slope - uOld.slope);
            if (lastPoint.bias < 0) lastPoint.bias = 0;
            if (lastPoint.slope < 0) lastPoint.slope = 0;
            pointHistory[epoch] = lastPoint;

            // --- Per-user checkpoint ---
            uint256 userEpoch = userPointEpoch[_addr] + 1;
            userPointEpoch[_addr] = userEpoch;
            uNew.ts = block.timestamp;
            uNew.blk = block.number;
            userPointHistory[_addr][userEpoch] = uNew;
        }
    }

    /**
     * @notice Trigger a global checkpoint (can be called by anyone).
     */
    function checkpoint() external {
        LockedBalance memory empty;
        _checkpoint(address(0), empty, empty);
    }

    // ---------------------------------------------------------------
    //  Views — Voting Power
    // ---------------------------------------------------------------

    /**
     * @notice Current veGX voting power for an address (decayed to now).
     * @param _addr The address to query.
     * @return Current voting power (0 if lock expired or no lock).
     */
    function balanceOf(address _addr) external view returns (uint256) {
        return _balanceOfAt(_addr, block.timestamp);
    }

    /**
     * @notice veGX voting power at a specific timestamp.
     * @param _addr The address to query.
     * @param _t Timestamp to evaluate.
     * @return Voting power at time _t.
     */
    function balanceOfAt(address _addr, uint256 _t) external view returns (uint256) {
        return _balanceOfAt(_addr, _t);
    }

    /**
     * @dev Internal balance calculation from user's last checkpoint.
     */
    function _balanceOfAt(address _addr, uint256 _t) internal view returns (uint256) {
        uint256 _epoch = userPointEpoch[_addr];
        if (_epoch == 0) return 0;

        // Binary search for the user checkpoint at or before _t.
        uint256 lo = 0;
        uint256 hi = _epoch;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (userPointHistory[_addr][mid].ts <= _t) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        Point memory uPoint = userPointHistory[_addr][lo];
        int128 bias = uPoint.bias - uPoint.slope * int128(int256(_t - uPoint.ts));
        if (bias < 0) bias = 0;
        return uint256(uint128(bias));
    }

    /**
     * @notice Total veGX voting power across all users (decayed to now).
     * @return Current total voting power.
     */
    function totalSupply() external view returns (uint256) {
        return _totalSupplyAt(block.timestamp);
    }

    /**
     * @notice Total veGX voting power at a specific timestamp.
     * @param _t Timestamp to evaluate.
     * @return Total voting power at time _t.
     */
    function totalSupplyAt(uint256 _t) external view returns (uint256) {
        return _totalSupplyAt(_t);
    }

    /**
     * @dev Internal total supply calculation from global checkpoints + slope changes.
     */
    function _totalSupplyAt(uint256 _t) internal view returns (uint256) {
        uint256 _epoch = epoch;
        // Binary search for the global checkpoint at or before _t.
        uint256 lo = 0;
        uint256 hi = _epoch;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (pointHistory[mid].ts <= _t) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        Point memory lastPoint = pointHistory[lo];
        // Walk forward from the checkpoint week-by-week, applying slope changes.
        uint256 tI = (lastPoint.ts / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; i++) {
            tI += WEEK;
            int128 dSlope = 0;
            if (tI > _t) {
                tI = _t;
            } else {
                dSlope = slopeChanges[tI];
            }
            lastPoint.bias -= lastPoint.slope * int128(int256(tI - lastPoint.ts));
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) lastPoint.bias = 0;
            if (lastPoint.slope < 0) lastPoint.slope = 0;
            lastPoint.ts = tI;
            if (tI == _t) break;
        }
        return uint256(uint128(lastPoint.bias));
    }

    // ---------------------------------------------------------------
    //  IVotes — Governor-compatible interface
    // ---------------------------------------------------------------

    /// @inheritdoc IVotes
    function getVotes(address account) external view override returns (uint256) {
        return _balanceOfAt(account, block.timestamp);
    }

    /// @inheritdoc IVotes
    function getPastVotes(address account, uint256 timepoint) external view override returns (uint256) {
        require(timepoint <= block.timestamp, "GXveToken: future lookup");
        return _balanceOfAt(account, timepoint);
    }

    /// @inheritdoc IVotes
    function getPastTotalSupply(uint256 timepoint) external view override returns (uint256) {
        require(timepoint <= block.timestamp, "GXveToken: future lookup");
        return _totalSupplyAt(timepoint);
    }

    /**
     * @notice Delegation is not supported — veGX is inherently non-delegatable.
     *         Voting power is tied to the lock owner.
     */
    function delegates(address account) external pure override returns (address) {
        return account; // self-delegation only
    }

    /// @notice Delegation not supported. Always reverts.
    function delegate(address) external pure override {
        revert NonTransferable();
    }

    /// @notice Delegation not supported. Always reverts.
    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure override {
        revert NonTransferable();
    }

    // ---------------------------------------------------------------
    //  ERC-165 — Interface detection
    // ---------------------------------------------------------------

    /// @notice Indicates support for IVotes, IERC5805, IERC6372 interfaces.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IVotes).interfaceId ||
            interfaceId == type(IERC6372).interfaceId ||
            interfaceId == 0x01ffc9a7; // ERC-165
    }
}
