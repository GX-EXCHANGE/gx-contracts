// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title GXBridge
 * @author GX Exchange
 * @notice Bridging contract for locking ERC-20 tokens on Arbitrum and releasing them on GX Chain.
 *         Based on the Gravity Bridge pattern with GX-specific enhancements:
 *         dispute periods, per-address rate limiting, and immutable supported-token list.
 *
 *         IMMUTABLE — no proxy, no admin upgrade, no owner. Once deployed the rules are final.
 *
 * @dev Validator set updates and withdrawals require 2/3+ stake-weighted multi-sig.
 *      Power is represented as uint256 values that sum to a total; the threshold for
 *      approval is > 2/3 of total power (constant_powerThreshold = 2^32 * 2/3 ≈ 2863311530).
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Custom errors
// ──────────────────────────────────────────────────────────────────────────────
error InvalidSignature();
error InvalidValsetNonce(uint256 newNonce, uint256 currentNonce);
error IncorrectCheckpoint();
error MalformedNewValidatorSet();
error MalformedCurrentValidatorSet();
error InsufficientPower(uint256 cumulativePower, uint256 powerThreshold);
error TokenNotSupported(address token);
error ZeroAmount();
error ZeroAddress();
error WithdrawalRateLimitExceeded(address user, uint256 requested, uint256 remaining);
error WithdrawalInDisputePeriod(uint256 withdrawalId);
error WithdrawalAlreadyExecuted(uint256 withdrawalId);
error WithdrawalNotFound(uint256 withdrawalId);
error WithdrawalDisputed(uint256 withdrawalId);
error DisputePeriodNotElapsed(uint256 withdrawalId, uint256 executeAfter);

// ──────────────────────────────────────────────────────────────────────────────
// Structs
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Represents a validator set snapshot.
struct ValsetArgs {
    address[] validators;
    uint256[] powers;
    uint256 valsetNonce;
}

/// @notice ECDSA signature components.
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @notice A queued withdrawal subject to the dispute period.
struct PendingWithdrawal {
    address token;
    address to;
    uint256 amount;
    uint256 executeAfter;   // timestamp after which the withdrawal can be finalised
    bool executed;
    bool disputed;
}

contract GXBridge is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice 2/3 of 2^32 — the minimum cumulative power required to approve an action.
    uint256 public constant POWER_THRESHOLD = 2_863_311_530;

    /// @notice Dispute period duration (1 hour).
    uint256 public constant DISPUTE_PERIOD = 1 hours;

    /// @notice Maximum total withdrawal amount per address per rolling 24-hour window.
    uint256 public constant RATE_LIMIT_PERIOD = 1 days;

    // ──────────────────────────────────────────────────────────────────────────
    // Immutable state (set once at deploy, never changed)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Unique identifier for this bridge instance, preventing cross-chain replays.
    bytes32 public immutable bridgeId;

    /// @notice Per-address daily withdrawal cap (in token-native decimals, same for all tokens).
    uint256 public immutable dailyWithdrawalLimit;

    // ──────────────────────────────────────────────────────────────────────────
    // Mutable state
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Checkpoint hash of the current validator set.
    bytes32 public lastValsetCheckpoint;

    /// @notice Nonce of the current validator set.
    uint256 public lastValsetNonce;

    /// @notice Monotonically increasing event counter for off-chain indexers.
    uint256 public lastEventNonce = 1;

    /// @notice Auto-incrementing withdrawal ID.
    uint256 public nextWithdrawalId = 1;

    /// @notice Supported tokens set at deployment (immutable after constructor).
    mapping(address => bool) public supportedTokens;

    /// @notice List of supported token addresses (for enumeration).
    address[] public supportedTokenList;

    /// @notice Pending withdrawals keyed by ID.
    mapping(uint256 => PendingWithdrawal) public pendingWithdrawals;

    /// @notice Rolling rate-limit tracker: user => token => DailyUsage.
    mapping(address => mapping(address => DailyUsage)) private _dailyUsage;

    struct DailyUsage {
        uint256 amount;
        uint256 resetTime;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    event Deposited(
        address indexed token,
        address indexed sender,
        string gxChainRecipient,
        uint256 amount,
        uint256 eventNonce
    );

    event WithdrawalQueued(
        uint256 indexed withdrawalId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 executeAfter,
        uint256 eventNonce
    );

    event WithdrawalExecuted(
        uint256 indexed withdrawalId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 eventNonce
    );

    event WithdrawalDisputeRaised(
        uint256 indexed withdrawalId,
        uint256 eventNonce
    );

    event ValsetUpdated(
        uint256 indexed newValsetNonce,
        uint256 eventNonce,
        address[] validators,
        uint256[] powers
    );

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor — sets all immutable / initial state
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @param _bridgeId            Unique bridge identifier (e.g. keccak256("gx-bridge-arbitrum-v1")).
     * @param _validators          Initial validator Ethereum addresses.
     * @param _powers              Corresponding stake-weighted powers.
     * @param _supportedTokens     Token addresses accepted by this bridge (e.g. USDC, USDT).
     * @param _dailyWithdrawalLimit Maximum withdrawal per address per 24 h (token-native units).
     */
    constructor(
        bytes32 _bridgeId,
        address[] memory _validators,
        uint256[] memory _powers,
        address[] memory _supportedTokens,
        uint256 _dailyWithdrawalLimit
    ) {
        if (_validators.length != _powers.length || _validators.length == 0) {
            revert MalformedCurrentValidatorSet();
        }
        if (_supportedTokens.length == 0) revert ZeroAmount();
        if (_dailyWithdrawalLimit == 0) revert ZeroAmount();

        // Verify cumulative power exceeds threshold
        uint256 cumulativePower;
        for (uint256 i; i < _powers.length; ++i) {
            cumulativePower += _powers[i];
            if (cumulativePower > POWER_THRESHOLD) break;
        }
        if (cumulativePower <= POWER_THRESHOLD) {
            revert InsufficientPower(cumulativePower, POWER_THRESHOLD);
        }

        // Register supported tokens (immutable after deploy — mapping cannot be modified)
        for (uint256 i; i < _supportedTokens.length; ++i) {
            if (_supportedTokens[i] == address(0)) revert ZeroAddress();
            supportedTokens[_supportedTokens[i]] = true;
            supportedTokenList.push(_supportedTokens[i]);
        }

        bridgeId = _bridgeId;
        dailyWithdrawalLimit = _dailyWithdrawalLimit;

        // Store initial valset checkpoint
        ValsetArgs memory valset = ValsetArgs(_validators, _powers, 0);
        bytes32 checkpoint = _makeCheckpoint(valset, _bridgeId);
        lastValsetCheckpoint = checkpoint;

        emit ValsetUpdated(0, lastEventNonce, _validators, _powers);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Deposit (Arbitrum → GX Chain)
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Lock ERC-20 tokens in this contract to be credited on GX Chain.
     * @param _token             Address of the ERC-20 token to deposit.
     * @param _amount            Amount to deposit (must have prior approval).
     * @param _gxChainRecipient  Destination address on GX Chain (e.g. "gx1abc...").
     */
    function deposit(
        address _token,
        uint256 _amount,
        string calldata _gxChainRecipient
    ) external nonReentrant {
        if (!supportedTokens[_token]) revert TokenNotSupported(_token);
        if (_amount == 0) revert ZeroAmount();

        // Snapshot balance to handle fee-on-transfer tokens
        uint256 balBefore = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 actualAmount = IERC20(_token).balanceOf(address(this)) - balBefore;

        lastEventNonce += 1;
        emit Deposited(_token, msg.sender, _gxChainRecipient, actualAmount, lastEventNonce);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Withdraw (GX Chain → Arbitrum) — two-phase: queue + execute
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Queue a withdrawal approved by 2/3+ validator stake weight.
     *         The withdrawal enters a 1-hour dispute period before it can be executed.
     * @param _token          Token to withdraw.
     * @param _to             Recipient on Arbitrum.
     * @param _amount         Amount to release.
     * @param _currentValset  Current validator set for signature verification.
     * @param _sigs           Validator signatures over the withdrawal message.
     */
    function withdraw(
        address _token,
        address _to,
        uint256 _amount,
        ValsetArgs calldata _currentValset,
        Signature[] calldata _sigs
    ) external nonReentrant {
        if (!supportedTokens[_token]) revert TokenNotSupported(_token);
        if (_amount == 0) revert ZeroAmount();
        if (_to == address(0)) revert ZeroAddress();

        // Validate current valset
        _validateValset(_currentValset, _sigs);
        if (_makeCheckpoint(_currentValset, bridgeId) != lastValsetCheckpoint) {
            revert IncorrectCheckpoint();
        }

        // Rate-limit check
        _enforceRateLimit(_to, _token, _amount);

        // Build withdrawal message hash
        uint256 wId = nextWithdrawalId++;
        bytes32 msgHash = keccak256(
            abi.encode(
                bridgeId,
                keccak256("withdraw"),
                _token,
                _to,
                _amount,
                wId
            )
        );

        // Verify 2/3+ signatures
        _checkValidatorSignatures(_currentValset, _sigs, msgHash, POWER_THRESHOLD);

        // Queue with dispute period
        uint256 executeAfter = block.timestamp + DISPUTE_PERIOD;
        pendingWithdrawals[wId] = PendingWithdrawal({
            token: _token,
            to: _to,
            amount: _amount,
            executeAfter: executeAfter,
            executed: false,
            disputed: false
        });

        lastEventNonce += 1;
        emit WithdrawalQueued(wId, _token, _to, _amount, executeAfter, lastEventNonce);
    }

    /**
     * @notice Execute a pending withdrawal after its dispute period has elapsed.
     * @param _withdrawalId ID of the withdrawal to finalise.
     */
    function executeWithdrawal(uint256 _withdrawalId) external nonReentrant {
        PendingWithdrawal storage w = pendingWithdrawals[_withdrawalId];
        if (w.amount == 0) revert WithdrawalNotFound(_withdrawalId);
        if (w.executed) revert WithdrawalAlreadyExecuted(_withdrawalId);
        if (w.disputed) revert WithdrawalDisputed(_withdrawalId);
        if (block.timestamp < w.executeAfter) {
            revert DisputePeriodNotElapsed(_withdrawalId, w.executeAfter);
        }

        w.executed = true;
        IERC20(w.token).safeTransfer(w.to, w.amount);

        lastEventNonce += 1;
        emit WithdrawalExecuted(_withdrawalId, w.token, w.to, w.amount, lastEventNonce);
    }

    /**
     * @notice Raise a dispute on a pending withdrawal (requires 2/3+ validator signatures).
     *         Disputed withdrawals are permanently blocked.
     * @param _withdrawalId   Withdrawal to dispute.
     * @param _currentValset  Current validator set.
     * @param _sigs           Validator signatures over the dispute message.
     */
    function disputeWithdrawal(
        uint256 _withdrawalId,
        ValsetArgs calldata _currentValset,
        Signature[] calldata _sigs
    ) external nonReentrant {
        PendingWithdrawal storage w = pendingWithdrawals[_withdrawalId];
        if (w.amount == 0) revert WithdrawalNotFound(_withdrawalId);
        if (w.executed) revert WithdrawalAlreadyExecuted(_withdrawalId);

        _validateValset(_currentValset, _sigs);
        if (_makeCheckpoint(_currentValset, bridgeId) != lastValsetCheckpoint) {
            revert IncorrectCheckpoint();
        }

        bytes32 msgHash = keccak256(
            abi.encode(bridgeId, keccak256("dispute"), _withdrawalId)
        );
        _checkValidatorSignatures(_currentValset, _sigs, msgHash, POWER_THRESHOLD);

        w.disputed = true;

        lastEventNonce += 1;
        emit WithdrawalDisputeRaised(_withdrawalId, lastEventNonce);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Validator set updates
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Update the validator set. Requires 2/3+ of the *current* set to sign
     *         a checkpoint of the *new* set.
     * @param _newValset      The new validator set.
     * @param _currentValset  The current validator set (must match stored checkpoint).
     * @param _sigs           Signatures from current validators over the new checkpoint.
     */
    function updateValset(
        ValsetArgs calldata _newValset,
        ValsetArgs calldata _currentValset,
        Signature[] calldata _sigs
    ) external {
        // Nonce must strictly increase
        if (_newValset.valsetNonce <= _currentValset.valsetNonce) {
            revert InvalidValsetNonce(_newValset.valsetNonce, _currentValset.valsetNonce);
        }
        // Prevent nonce jumps > 1 000 000 to avoid lockout attacks
        if (_newValset.valsetNonce > _currentValset.valsetNonce + 1_000_000) {
            revert InvalidValsetNonce(_newValset.valsetNonce, _currentValset.valsetNonce);
        }

        // New set well-formed
        if (
            _newValset.validators.length != _newValset.powers.length ||
            _newValset.validators.length == 0
        ) {
            revert MalformedNewValidatorSet();
        }

        // Current set well-formed
        _validateValset(_currentValset, _sigs);

        // New set has enough cumulative power
        uint256 cumPower;
        for (uint256 i; i < _newValset.powers.length; ++i) {
            cumPower += _newValset.powers[i];
            if (cumPower > POWER_THRESHOLD) break;
        }
        if (cumPower <= POWER_THRESHOLD) {
            revert InsufficientPower(cumPower, POWER_THRESHOLD);
        }

        // Current checkpoint must match
        if (_makeCheckpoint(_currentValset, bridgeId) != lastValsetCheckpoint) {
            revert IncorrectCheckpoint();
        }

        // Verify current validators signed the new checkpoint
        bytes32 newCheckpoint = _makeCheckpoint(_newValset, bridgeId);
        _checkValidatorSignatures(_currentValset, _sigs, newCheckpoint, POWER_THRESHOLD);

        // Commit
        lastValsetCheckpoint = newCheckpoint;
        lastValsetNonce = _newValset.valsetNonce;

        lastEventNonce += 1;
        emit ValsetUpdated(
            _newValset.valsetNonce,
            lastEventNonce,
            _newValset.validators,
            _newValset.powers
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    // View helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Number of supported tokens.
    function supportedTokenCount() external view returns (uint256) {
        return supportedTokenList.length;
    }

    /// @notice Remaining daily withdrawal allowance for a user + token pair.
    function remainingDailyAllowance(address _user, address _token) external view returns (uint256) {
        DailyUsage storage u = _dailyUsage[_user][_token];
        if (block.timestamp >= u.resetTime) {
            return dailyWithdrawalLimit;
        }
        if (u.amount >= dailyWithdrawalLimit) {
            return 0;
        }
        return dailyWithdrawalLimit - u.amount;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @dev Create a checkpoint hash from a validator set.
     */
    function _makeCheckpoint(
        ValsetArgs memory _valset,
        bytes32 _bridgeId
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _bridgeId,
                keccak256("checkpoint"),
                _valset.valsetNonce,
                _valset.validators,
                _valset.powers
            )
        );
    }

    /**
     * @dev Verify geth-style ECDSA signature.
     */
    function _verifySig(
        address _signer,
        bytes32 _hash,
        Signature calldata _sig
    ) private pure returns (bool) {
        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", _hash)
        );
        return _signer == ECDSA.recover(digest, _sig.v, _sig.r, _sig.s);
    }

    /**
     * @dev Ensure validators and signatures arrays have matching length.
     */
    function _validateValset(
        ValsetArgs calldata _valset,
        Signature[] calldata _sigs
    ) private pure {
        if (
            _valset.validators.length != _valset.powers.length ||
            _valset.validators.length != _sigs.length
        ) {
            revert MalformedCurrentValidatorSet();
        }
    }

    /**
     * @dev Verify that cumulative signing power exceeds the threshold.
     */
    function _checkValidatorSignatures(
        ValsetArgs calldata _valset,
        Signature[] calldata _sigs,
        bytes32 _hash,
        uint256 _powerThreshold
    ) private pure {
        uint256 cumulativePower;
        for (uint256 i; i < _valset.validators.length; ++i) {
            // v == 0 means validator did not sign — skip
            if (_sigs[i].v != 0) {
                if (!_verifySig(_valset.validators[i], _hash, _sigs[i])) {
                    revert InvalidSignature();
                }
                cumulativePower += _valset.powers[i];
                if (cumulativePower > _powerThreshold) break;
            }
        }
        if (cumulativePower <= _powerThreshold) {
            revert InsufficientPower(cumulativePower, _powerThreshold);
        }
    }

    /**
     * @dev Enforce per-address daily withdrawal rate limit.
     */
    function _enforceRateLimit(address _user, address _token, uint256 _amount) private {
        DailyUsage storage u = _dailyUsage[_user][_token];

        // Reset window if elapsed
        if (block.timestamp >= u.resetTime) {
            u.amount = 0;
            u.resetTime = block.timestamp + RATE_LIMIT_PERIOD;
        }

        uint256 remaining = dailyWithdrawalLimit > u.amount
            ? dailyWithdrawalLimit - u.amount
            : 0;

        if (_amount > remaining) {
            revert WithdrawalRateLimitExceeded(_user, _amount, remaining);
        }

        u.amount += _amount;
    }
}
