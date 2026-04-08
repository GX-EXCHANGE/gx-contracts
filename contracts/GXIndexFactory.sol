// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GXIndexFactory
 * @author GX Exchange
 * @notice Factory contract for deploying new GXIndex instances.
 *         Each index is an independent ERC-20 that holds real underlying tokens.
 *         Owner (GX Exchange multisig) controls creation of new indexes.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "./GXIndex.sol";

contract GXIndexFactory is Ownable {

    // ── State ───────────────────────────────────────────────────────────

    address[] public indexes;
    mapping(address => bool) public isIndex;

    // Default fee settings for new indexes (can be overridden per-index after creation)
    uint256 public defaultMintFeeBps;   // e.g. 10 = 0.10%
    uint256 public defaultBurnFeeBps;   // e.g. 10 = 0.10%

    // ── Events ──────────────────────────────────────────────────────────

    event IndexCreated(
        address indexed indexAddress,
        string name,
        string symbol,
        address usdc,
        address rebalancer,
        uint256 managementFeeBps
    );

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();

    // ── Constructor ─────────────────────────────────────────────────────

    /**
     * @param _defaultMintFeeBps Default mint fee for new indexes
     * @param _defaultBurnFeeBps Default burn fee for new indexes
     */
    constructor(
        uint256 _defaultMintFeeBps,
        uint256 _defaultBurnFeeBps
    ) Ownable(msg.sender) {
        defaultMintFeeBps = _defaultMintFeeBps;
        defaultBurnFeeBps = _defaultBurnFeeBps;
    }

    // ══════════════════════════════════════════════════════════════════
    //  INDEX CREATION
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy a new GXIndex contract.
     * @param name             ERC-20 name (e.g. "GX Crypto Index 10")
     * @param symbol           ERC-20 symbol (e.g. "GXI10")
     * @param _usdc            USDC token address on this chain
     * @param _rebalancer      Address authorized to rebalance the index
     * @param _managementFeeBps Annual management fee in basis points
     * @return indexAddress     Address of the newly deployed GXIndex
     */
    function createIndex(
        string memory name,
        string memory symbol,
        address _usdc,
        address _rebalancer,
        uint256 _managementFeeBps
    ) external onlyOwner returns (address indexAddress) {
        if (_usdc == address(0)) revert ZeroAddress();

        GXIndex index = new GXIndex(
            name,
            symbol,
            _usdc,
            _rebalancer,
            _managementFeeBps,
            defaultMintFeeBps,
            defaultBurnFeeBps
        );

        indexAddress = address(index);

        // Transfer ownership of the index to the factory owner (GX Exchange multisig)
        index.transferOwnership(msg.sender);

        indexes.push(indexAddress);
        isIndex[indexAddress] = true;

        emit IndexCreated(indexAddress, name, symbol, _usdc, _rebalancer, _managementFeeBps);
    }

    // ══════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Get all deployed index addresses.
     */
    function getAllIndexes() external view returns (address[] memory) {
        return indexes;
    }

    /**
     * @notice Get the total number of deployed indexes.
     */
    function getIndexCount() external view returns (uint256) {
        return indexes.length;
    }

    // ══════════════════════════════════════════════════════════════════
    //  ADMIN
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Update default fee settings for future index deployments.
     */
    function setDefaultFees(uint256 _mintFeeBps, uint256 _burnFeeBps) external onlyOwner {
        defaultMintFeeBps = _mintFeeBps;
        defaultBurnFeeBps = _burnFeeBps;
    }
}
