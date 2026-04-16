// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title GXAirdrop
 * @author GX Exchange
 * @notice Merkle-tree-based airdrop distributor for the GX token.
 *         Forked from Uniswap's MerkleDistributor with the following changes:
 *           - Upgraded to Solidity 0.8.24
 *           - 90-day claim deadline (immutable, set at deployment)
 *           - sweep() sends unclaimed tokens to treasury after the deadline
 *
 *         IMMUTABLE — no proxy, no admin upgrade, no owner.
 *
 * @dev Each leaf in the Merkle tree is `keccak256(abi.encodePacked(index, account, amount))`.
 *      Claiming is gas-efficient: a packed bitmap tracks which indices have been claimed.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Custom errors
// ──────────────────────────────────────────────────────────────────────────────
error AlreadyClaimed();
error InvalidProof();
error ClaimDeadlinePassed();
error ClaimDeadlineNotPassed();
error ZeroAddress();
error SweepAlreadyDone();

contract GXAirdrop {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    // Immutable state
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice The ERC-20 token being distributed.
    address public immutable token;

    /// @notice Root of the Merkle tree encoding all airdrop allocations.
    bytes32 public immutable merkleRoot;

    /// @notice Unix timestamp after which no more claims are accepted.
    uint256 public immutable claimDeadline;

    /// @notice Treasury address that receives unclaimed tokens after the deadline.
    address public immutable treasury;

    // ──────────────────────────────────────────────────────────────────────────
    // Mutable state
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Packed bitmap of claimed indices (256 claims per storage slot).
    mapping(uint256 => uint256) private _claimedBitMap;

    /// @notice Whether the sweep has already been executed.
    bool public swept;

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when an account successfully claims their allocation.
    event Claimed(uint256 indexed index, address indexed account, uint256 amount);

    /// @notice Emitted when unclaimed tokens are swept to the treasury.
    event Swept(address indexed treasury, uint256 amount);

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @param _token       Address of the ERC-20 token to distribute.
     * @param _merkleRoot  Root hash of the allocation Merkle tree.
     * @param _treasury    Address that receives unclaimed tokens after the deadline.
     */
    constructor(address _token, bytes32 _merkleRoot, address _treasury) {
        if (_token == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        token = _token;
        merkleRoot = _merkleRoot;
        treasury = _treasury;
        claimDeadline = block.timestamp + 90 days;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Claim
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Check whether index `_index` has already been claimed.
     * @param _index The allocation index in the Merkle tree.
     * @return True if already claimed.
     */
    function isClaimed(uint256 _index) public view returns (bool) {
        uint256 wordIndex = _index / 256;
        uint256 bitIndex = _index % 256;
        uint256 word = _claimedBitMap[wordIndex];
        uint256 mask = (1 << bitIndex);
        return word & mask == mask;
    }

    /**
     * @notice Claim airdrop allocation for `_account`.
     * @dev Anyone can submit a claim on behalf of the account, but tokens always go
     *      to the account encoded in the Merkle leaf.
     * @param _index       Index in the Merkle tree.
     * @param _account     The beneficiary address.
     * @param _amount      Token amount allocated.
     * @param _merkleProof Proof that (index, account, amount) is in the tree.
     */
    function claim(
        uint256 _index,
        address _account,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    ) external {
        if (block.timestamp > claimDeadline) revert ClaimDeadlinePassed();
        if (isClaimed(_index)) revert AlreadyClaimed();

        // Verify Merkle proof
        bytes32 node = keccak256(abi.encodePacked(_index, _account, _amount));
        if (!MerkleProof.verify(_merkleProof, merkleRoot, node)) revert InvalidProof();

        // Mark claimed
        _setClaimed(_index);

        // Transfer tokens
        IERC20(token).safeTransfer(_account, _amount);

        emit Claimed(_index, _account, _amount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Sweep
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice After the claim deadline, send all remaining tokens to the treasury.
     *         Can only be called once.
     */
    function sweep() external {
        if (block.timestamp <= claimDeadline) revert ClaimDeadlineNotPassed();
        if (swept) revert SweepAlreadyDone();

        swept = true;

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(treasury, balance);
        }

        emit Swept(treasury, balance);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @dev Set the claimed bit for a given index.
     */
    function _setClaimed(uint256 _index) private {
        uint256 wordIndex = _index / 256;
        uint256 bitIndex = _index % 256;
        _claimedBitMap[wordIndex] = _claimedBitMap[wordIndex] | (1 << bitIndex);
    }
}
