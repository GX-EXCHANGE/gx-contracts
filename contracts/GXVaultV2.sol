// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title GXVaultV2
 * @author GX Exchange Security Team
 * @notice Multi-validator quorum bridge vault for GX Exchange on Arbitrum.
 *         Upgrades GXVault (single-signer) to a full multi-validator quorum model
 *         where 2/3+ of the validator set must sign every withdrawal.
 *
 * KEY UPGRADES OVER GXVaultV1:
 *   - ValidatorSet management via quorum vote (not single owner)
 *   - Withdrawal request → multi-sign → execute lifecycle
 *   - 24-hour dispute timelock on large withdrawals (>100k USDC)
 *   - Emergency pause/unpause requires 2/3 validator vote
 *   - Withdrawal batching to reduce gas costs
 *   - USDC (6 decimals) as primary bridge asset
 *
 * SECURITY: Retains all Zellic Bridge2.sol audit remediations from V1 (FIX-1..FIX-9).
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ── Arbitrum L2 block number interface ────────────────────────────────
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

contract GXVaultV2 is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Minimum deposit: 1 USDC (6 decimals)
    uint256 public constant MIN_DEPOSIT = 1e6;

    /// @notice Standard withdrawal delay for small amounts
    uint256 public constant WITHDRAWAL_DELAY = 1 hours;

    /// @notice Extended dispute period for large withdrawals (24 hours)
    uint256 public constant LARGE_WITHDRAWAL_DELAY = 24 hours;

    /// @notice Threshold above which the 24h dispute period applies (100,000 USDC)
    uint256 public constant LARGE_WITHDRAWAL_THRESHOLD = 100_000e6;

    /// @notice Maximum number of validators in the set
    uint256 public constant MAX_VALIDATORS = 50;

    /// @notice Maximum withdrawals per batch execution
    uint256 public constant MAX_BATCH_SIZE = 20;

    /// @notice Arbitrum precompile for accurate L2 block numbers (FIX-7)
    IArbSys private constant ARB_SYS = IArbSys(address(0x0000000000000000000000000000000000000064));

    /// @notice EIP-712 domain separator (FIX-4: includes address(this))
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ── Type Hashes (FIX-5: action prefix in all signatures) ─────────

    bytes32 public constant WITHDRAW_TYPEHASH = keccak256(
        "GXVaultWithdraw(address token,address to,uint256 amount,bytes32 withdrawalId)"
    );

    bytes32 public constant ADD_VALIDATOR_TYPEHASH = keccak256(
        "AddValidator(address validator,uint256 nonce)"
    );

    bytes32 public constant REMOVE_VALIDATOR_TYPEHASH = keccak256(
        "RemoveValidator(address validator,uint256 nonce)"
    );

    bytes32 public constant EMERGENCY_PAUSE_TYPEHASH = keccak256(
        "EmergencyPause(bool pause,uint256 nonce)"
    );

    // ══════════════════════════════════════════════════════════════════
    //  STATE
    // ══════════════════════════════════════════════════════════════════

    /// @notice Contract owner (for initial setup; critical ops require quorum)
    address public owner;

    /// @notice Nonce for governance operations (prevents replay)
    uint256 public governanceNonce;

    /// @notice Maximum total deposits allowed
    uint256 public maxTotalDeposits;

    /// @notice Total deposited across all users
    uint256 public totalDeposited;

    /// @notice Number of active validators
    uint256 public validatorCount;

    /// @notice Validator set
    mapping(address => bool) public validators;

    /// @notice Approved ERC-20 tokens for deposits
    mapping(address => bool) public approvedTokens;

    /// @notice User balances: token => user => amount
    mapping(address => mapping(address => uint256)) public balances;

    // ── Withdrawal State ─────────────────────────────────────────────

    enum WithdrawalStatus {
        None,
        Requested,    // User has requested, awaiting validator signatures
        Approved,     // Quorum reached, timelock started
        Executed,     // Funds released
        Cancelled     // Cancelled (by dispute or emergency)
    }

    struct WithdrawalRequest {
        address token;
        address to;
        uint256 amount;
        uint256 signatureCount;
        uint256 executeAfter;       // Timelock expiry (0 if not yet approved)
        WithdrawalStatus status;
    }

    /// @notice All withdrawal requests by ID
    mapping(bytes32 => WithdrawalRequest) public withdrawalRequests;

    /// @notice Tracks which validators have signed each withdrawal
    mapping(bytes32 => mapping(address => bool)) public withdrawalSignatures;

    /// @notice Processed withdrawal IDs (prevents replay)
    mapping(bytes32 => bool) public processedWithdrawals;

    /// @notice Pending withdrawal IDs for emergency cancellation (FIX-2)
    bytes32[] private _pendingWithdrawalIds;
    mapping(bytes32 => uint256) private _pendingWithdrawalIndex; // 1-indexed

    // ══════════════════════════════════════════════════════════════════
    //  ERRORS
    // ══════════════════════════════════════════════════════════════════

    error NotOwner();
    error InvalidAddress();
    error InvalidValidator();
    error ValidatorAlreadyExists();
    error ValidatorDoesNotExist();
    error TokenNotApproved();
    error BelowMinimumDeposit();
    error DepositCapExceeded();
    error InsufficientBalance();
    error InvalidSignatureCount();
    error DuplicateSignature();
    error WithdrawalAlreadyProcessed();
    error WithdrawalNotFound();
    error WithdrawalNotApproved();
    error WithdrawalTimelockActive();
    error TooManyValidators();
    error InvalidSignature();
    error SignerNotValidator();
    error InvalidWithdrawalStatus();
    error BatchTooLarge();
    error InvalidNonce();

    // ══════════════════════════════════════════════════════════════════
    //  EVENTS
    // ══════════════════════════════════════════════════════════════════

    event Deposited(address indexed token, address indexed user, uint256 amount);

    event WithdrawalRequested(
        bytes32 indexed withdrawalId,
        address indexed token,
        address indexed to,
        uint256 amount
    );

    event WithdrawalApproved(
        bytes32 indexed withdrawalId,
        address indexed validator,
        uint256 signatureCount,
        uint256 requiredCount
    );

    event WithdrawalExecuted(
        bytes32 indexed withdrawalId,
        address indexed token,
        address indexed to,
        uint256 amount
    );

    event WithdrawalCancelled(bytes32 indexed withdrawalId);

    event ValidatorAdded(address indexed validator, uint256 newValidatorCount);

    event ValidatorRemoved(address indexed validator, uint256 newValidatorCount);

    event EmergencyPause(bool paused, uint256 pendingCancelled);

    event TokenApproved(address indexed token);
    event TokenRemoved(address indexed token);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);

    // ══════════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ══════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ══════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    constructor(
        address[] memory _validators,
        uint256 _maxTotalDeposits
    ) {
        if (_validators.length == 0) revert InvalidValidator();
        if (_validators.length > MAX_VALIDATORS) revert TooManyValidators();

        owner = msg.sender;

        for (uint256 i = 0; i < _validators.length; i++) {
            if (_validators[i] == address(0)) revert InvalidAddress();
            if (validators[_validators[i]]) revert DuplicateSignature();
            validators[_validators[i]] = true;
        }
        validatorCount = _validators.length;
        maxTotalDeposits = _maxTotalDeposits;

        // EIP-712 domain separator (FIX-4)
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("GXVaultV2"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  DEPOSITS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit approved ERC-20 tokens (primarily USDC, 6 decimals).
     * @dev FIX-1: nonReentrant only on external entry.
     *      FIX-6: SafeERC20 for all transfers.
     *      FIX-9: Event emitted after state change, before external call.
     */
    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (!approvedTokens[token]) revert TokenNotApproved();
        if (amount < MIN_DEPOSIT) revert BelowMinimumDeposit();
        if (totalDeposited + amount > maxTotalDeposits) revert DepositCapExceeded();

        // Effects
        balances[token][msg.sender] += amount;
        totalDeposited += amount;

        // FIX-9: Event after state changes
        emit Deposited(token, msg.sender, amount);

        // Interaction (last) -- FIX-6
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    // ══════════════════════════════════════════════════════════════════
    //  WITHDRAWAL LIFECYCLE: Request → Sign → Execute
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Step 1: User (or relayer) requests a withdrawal. No signatures needed yet.
     * @param token The ERC-20 token address (USDC)
     * @param to Recipient address
     * @param amount Amount in token's atomic units (6 decimals for USDC)
     * @param withdrawalId Unique ID for this withdrawal (derived off-chain from consensus)
     */
    function requestWithdrawal(
        address token,
        address to,
        uint256 amount,
        bytes32 withdrawalId
    ) external nonReentrant whenNotPaused {
        if (to == address(0)) revert InvalidAddress();
        if (processedWithdrawals[withdrawalId]) revert WithdrawalAlreadyProcessed();
        if (withdrawalRequests[withdrawalId].status != WithdrawalStatus.None) {
            revert InvalidWithdrawalStatus();
        }
        if (balances[token][to] < amount) revert InsufficientBalance();

        // Create the withdrawal request
        withdrawalRequests[withdrawalId] = WithdrawalRequest({
            token: token,
            to: to,
            amount: amount,
            signatureCount: 0,
            executeAfter: 0,
            status: WithdrawalStatus.Requested
        });

        // Track for emergency cancellation (FIX-2)
        _pendingWithdrawalIds.push(withdrawalId);
        _pendingWithdrawalIndex[withdrawalId] = _pendingWithdrawalIds.length;

        emit WithdrawalRequested(withdrawalId, token, to, amount);
    }

    /**
     * @notice Step 2: Validator approves a withdrawal with their signature.
     *         When 2/3+ signatures are collected, the withdrawal moves to Approved
     *         and the timelock begins.
     * @param withdrawalId The withdrawal to approve
     * @param signature The validator's EIP-712 signature
     */
    function approveWithdrawal(
        bytes32 withdrawalId,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        if (req.status != WithdrawalStatus.Requested) revert InvalidWithdrawalStatus();

        // Verify signature: EIP-712 typed data (FIX-5)
        bytes32 structHash = keccak256(
            abi.encode(WITHDRAW_TYPEHASH, req.token, req.to, req.amount, withdrawalId)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = ECDSA.recover(digest, signature);
        if (!validators[signer]) revert SignerNotValidator();
        if (withdrawalSignatures[withdrawalId][signer]) revert DuplicateSignature();

        // Record this validator's approval
        withdrawalSignatures[withdrawalId][signer] = true;
        req.signatureCount++;

        uint256 required = _quorumThreshold();

        emit WithdrawalApproved(withdrawalId, signer, req.signatureCount, required);

        // Check if quorum reached (FIX-8: strict >2/3)
        if (req.signatureCount * 3 > validatorCount * 2) {
            req.status = WithdrawalStatus.Approved;

            // Apply timelock: 24h for large withdrawals, 1h for small
            if (req.amount > LARGE_WITHDRAWAL_THRESHOLD) {
                req.executeAfter = block.timestamp + LARGE_WITHDRAWAL_DELAY;
            } else {
                req.executeAfter = block.timestamp + WITHDRAWAL_DELAY;
            }
        }
    }

    /**
     * @notice Step 3: Execute an approved withdrawal after its timelock expires.
     * @dev FIX-3: Validates parameters match stored request.
     *      FIX-6: SafeERC20 for transfer.
     *      FIX-9: Event before external call.
     */
    function executeWithdrawal(
        bytes32 withdrawalId
    ) external nonReentrant whenNotPaused {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];

        if (req.status != WithdrawalStatus.Approved) revert WithdrawalNotApproved();
        if (block.timestamp < req.executeAfter) revert WithdrawalTimelockActive();
        if (processedWithdrawals[withdrawalId]) revert WithdrawalAlreadyProcessed();
        if (balances[req.token][req.to] < req.amount) revert InsufficientBalance();

        // Effects
        processedWithdrawals[withdrawalId] = true;
        req.status = WithdrawalStatus.Executed;
        balances[req.token][req.to] -= req.amount;
        totalDeposited -= req.amount;

        // Clean up pending tracking
        _removePendingWithdrawal(withdrawalId);

        // FIX-9: Event after state changes, before external call
        emit WithdrawalExecuted(withdrawalId, req.token, req.to, req.amount);

        // Interaction (last) -- FIX-6
        IERC20(req.token).safeTransfer(req.to, req.amount);
    }

    /**
     * @notice Execute a batch of approved withdrawals in a single transaction.
     *         Reduces gas costs by amortizing base tx overhead across multiple withdrawals.
     * @param withdrawalIds Array of withdrawal IDs to execute
     */
    function executeBatchWithdrawals(
        bytes32[] calldata withdrawalIds
    ) external nonReentrant whenNotPaused {
        if (withdrawalIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        for (uint256 i = 0; i < withdrawalIds.length; i++) {
            bytes32 wId = withdrawalIds[i];
            WithdrawalRequest storage req = withdrawalRequests[wId];

            if (req.status != WithdrawalStatus.Approved) revert WithdrawalNotApproved();
            if (block.timestamp < req.executeAfter) revert WithdrawalTimelockActive();
            if (processedWithdrawals[wId]) revert WithdrawalAlreadyProcessed();
            if (balances[req.token][req.to] < req.amount) revert InsufficientBalance();

            // Effects
            processedWithdrawals[wId] = true;
            req.status = WithdrawalStatus.Executed;
            balances[req.token][req.to] -= req.amount;
            totalDeposited -= req.amount;

            _removePendingWithdrawal(wId);

            emit WithdrawalExecuted(wId, req.token, req.to, req.amount);

            // Transfer for each withdrawal in the batch
            IERC20(req.token).safeTransfer(req.to, req.amount);
        }
    }

    /**
     * @notice Cancel a pending withdrawal (owner only, for non-quorum cancellation).
     */
    function cancelWithdrawal(bytes32 withdrawalId) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        if (req.status != WithdrawalStatus.Requested && req.status != WithdrawalStatus.Approved) {
            revert InvalidWithdrawalStatus();
        }

        _cancelWithdrawalInternal(withdrawalId);
    }

    // ══════════════════════════════════════════════════════════════════
    //  VALIDATOR SET MANAGEMENT (quorum-governed)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Add a validator to the set. Requires 2/3+ validator signatures.
     * @param validator Address of the new validator
     * @param nonce Governance nonce (must match current governanceNonce)
     * @param signatures Array of validator EIP-712 signatures
     */
    function addValidator(
        address validator,
        uint256 nonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (validator == address(0)) revert InvalidAddress();
        if (validators[validator]) revert ValidatorAlreadyExists();
        if (validatorCount >= MAX_VALIDATORS) revert TooManyValidators();
        if (nonce != governanceNonce) revert InvalidNonce();

        // Verify quorum signatures
        bytes32 structHash = keccak256(
            abi.encode(ADD_VALIDATOR_TYPEHASH, validator, nonce)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        _verifyValidatorSignatures(digest, signatures);

        // Effects
        validators[validator] = true;
        validatorCount++;
        governanceNonce++;

        emit ValidatorAdded(validator, validatorCount);
    }

    /**
     * @notice Remove a validator from the set. Requires 2/3+ validator signatures.
     * @param validator Address of the validator to remove
     * @param nonce Governance nonce (must match current governanceNonce)
     * @param signatures Array of validator EIP-712 signatures
     */
    function removeValidator(
        address validator,
        uint256 nonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (!validators[validator]) revert ValidatorDoesNotExist();
        if (nonce != governanceNonce) revert InvalidNonce();
        // Ensure we keep at least 1 validator
        if (validatorCount <= 1) revert InvalidSignatureCount();

        // Verify quorum signatures
        bytes32 structHash = keccak256(
            abi.encode(REMOVE_VALIDATOR_TYPEHASH, validator, nonce)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        _verifyValidatorSignatures(digest, signatures);

        // Effects
        validators[validator] = false;
        validatorCount--;
        governanceNonce++;

        emit ValidatorRemoved(validator, validatorCount);
    }

    // ══════════════════════════════════════════════════════════════════
    //  EMERGENCY PAUSE (quorum-governed) -- FIX-2
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Emergency pause: requires 2/3 validator vote.
     *         Halts all operations AND cancels every pending withdrawal.
     * @param nonce Governance nonce
     * @param signatures Validator signatures for the pause action
     */
    function emergencyPauseByQuorum(
        uint256 nonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (nonce != governanceNonce) revert InvalidNonce();

        bytes32 structHash = keccak256(
            abi.encode(EMERGENCY_PAUSE_TYPEHASH, true, nonce)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        _verifyValidatorSignatures(digest, signatures);

        _pause();
        governanceNonce++;

        // Cancel all pending withdrawals (FIX-2)
        uint256 cancelledCount = _pendingWithdrawalIds.length;
        for (uint256 i = _pendingWithdrawalIds.length; i > 0; i--) {
            bytes32 wId = _pendingWithdrawalIds[i - 1];
            WithdrawalRequest storage req = withdrawalRequests[wId];
            if (req.status == WithdrawalStatus.Requested || req.status == WithdrawalStatus.Approved) {
                req.status = WithdrawalStatus.Cancelled;
                emit WithdrawalCancelled(wId);
            }
        }
        delete _pendingWithdrawalIds;

        emit EmergencyPause(true, cancelledCount);
    }

    /**
     * @notice Unpause: requires 2/3 validator vote.
     * @param nonce Governance nonce
     * @param signatures Validator signatures for the unpause action
     */
    function unpauseByQuorum(
        uint256 nonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (nonce != governanceNonce) revert InvalidNonce();

        bytes32 structHash = keccak256(
            abi.encode(EMERGENCY_PAUSE_TYPEHASH, false, nonce)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        _verifyValidatorSignatures(digest, signatures);

        _unpause();
        governanceNonce++;

        emit EmergencyPause(false, 0);
    }

    // ══════════════════════════════════════════════════════════════════
    //  ADMIN (owner-only for non-critical ops)
    // ══════════════════════════════════════════════════════════════════

    function addToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        approvedTokens[token] = true;
        emit TokenApproved(token);
    }

    function removeToken(address token) external onlyOwner {
        approvedTokens[token] = false;
        emit TokenRemoved(token);
    }

    function setMaxTotalDeposits(uint256 _maxTotalDeposits) external onlyOwner {
        maxTotalDeposits = _maxTotalDeposits;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ══════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    function getBalance(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    /// @notice Returns the current L2 block number on Arbitrum (FIX-7)
    function getBlockNumber() external view returns (uint256) {
        return ARB_SYS.arbBlockNumber();
    }

    function getPendingWithdrawalCount() external view returns (uint256) {
        return _pendingWithdrawalIds.length;
    }

    /// @notice Returns the number of signatures required for quorum (strict >2/3)
    function _quorumThreshold() internal view returns (uint256) {
        // Smallest n such that n * 3 > validatorCount * 2
        return (validatorCount * 2) / 3 + 1;
    }

    /// @notice Public getter for quorum threshold
    function quorumThreshold() external view returns (uint256) {
        return _quorumThreshold();
    }

    function getWithdrawalRequest(bytes32 withdrawalId) external view returns (
        address token,
        address to,
        uint256 amount,
        uint256 signatureCount,
        uint256 executeAfter,
        WithdrawalStatus status
    ) {
        WithdrawalRequest memory req = withdrawalRequests[withdrawalId];
        return (req.token, req.to, req.amount, req.signatureCount, req.executeAfter, req.status);
    }

    // ══════════════════════════════════════════════════════════════════
    //  INTERNAL -- FIX-1: No nonReentrant on internal functions
    // ══════════════════════════════════════════════════════════════════

    /**
     * @dev Verify an array of validator ECDSA signatures meet quorum (>2/3).
     *      Signatures must be sorted by signer address (ascending) to detect duplicates.
     */
    function _verifyValidatorSignatures(
        bytes32 digest,
        bytes[] calldata signatures
    ) internal view {
        // FIX-8: Strict >2/3 supermajority
        if (signatures.length * 3 <= validatorCount * 2) revert InvalidSignatureCount();

        address lastSigner = address(0);

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);

            if (!validators[signer]) revert SignerNotValidator();
            if (signer <= lastSigner) revert DuplicateSignature();
            lastSigner = signer;
        }
    }

    /**
     * @dev Internal cancellation logic.
     */
    function _cancelWithdrawalInternal(bytes32 withdrawalId) internal {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        req.status = WithdrawalStatus.Cancelled;
        _removePendingWithdrawal(withdrawalId);
        emit WithdrawalCancelled(withdrawalId);
    }

    /**
     * @dev Remove a withdrawal ID from _pendingWithdrawalIds (swap-and-pop).
     */
    function _removePendingWithdrawal(bytes32 withdrawalId) internal {
        uint256 idx = _pendingWithdrawalIndex[withdrawalId];
        if (idx == 0) return;

        uint256 lastIdx = _pendingWithdrawalIds.length;
        if (idx != lastIdx) {
            bytes32 lastId = _pendingWithdrawalIds[lastIdx - 1];
            _pendingWithdrawalIds[idx - 1] = lastId;
            _pendingWithdrawalIndex[lastId] = idx;
        }
        _pendingWithdrawalIds.pop();
        delete _pendingWithdrawalIndex[withdrawalId];
    }
}
