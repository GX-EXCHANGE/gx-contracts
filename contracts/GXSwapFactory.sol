// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./GXSwapPair.sol";

/// @title GXSwapFactory
/// @author GX Exchange
/// @notice Deterministic factory for GXSwapPair constant-product AMM pools.
/// @dev IMMUTABLE -- no owner, no admin functions, no upgradability.
///      Pairs are created via CREATE2 so their addresses are deterministic.
contract GXSwapFactory {
    // ---------------------------------------------------------------
    //  State
    // ---------------------------------------------------------------

    /// @notice Mapping from (tokenA, tokenB) to deployed pair address.
    ///         Both orderings return the same pair.
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Array of all deployed pairs.
    address[] public allPairs;

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    /// @notice Emitted when a new pair is created.
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256 pairIndex
    );

    // ---------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();

    // ---------------------------------------------------------------
    //  View helpers
    // ---------------------------------------------------------------

    /// @notice Total number of pairs created.
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    // ---------------------------------------------------------------
    //  Pair creation
    // ---------------------------------------------------------------

    /// @notice Deploy a new GXSwapPair for the given token pair.
    /// @dev Tokens are sorted internally; either ordering is accepted.
    ///      Uses CREATE2 with the sorted token pair as the salt so pair
    ///      addresses are deterministic.
    /// @param tokenA One of the two tokens.
    /// @param tokenB The other token.
    /// @return pair Address of the newly created pair.
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair)
    {
        if (tokenA == tokenB) revert IdenticalAddresses();

        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        // Deploy via CREATE2 for deterministic addresses.
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        GXSwapPair _pair = new GXSwapPair{salt: salt}(token0, token1);
        pair = address(_pair);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length - 1);
    }
}
