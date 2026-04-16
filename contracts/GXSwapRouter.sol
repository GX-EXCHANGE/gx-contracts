// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./GXSwapFactory.sol";
import "./GXSwapPair.sol";

/// @title GXSwapRouter
/// @author GX Exchange
/// @notice Stateless router for multi-hop swaps and liquidity management on
///         GXSwapPair constant-product AMM pools.
/// @dev IMMUTABLE -- no owner, no admin functions, no upgradability.
///      The router never holds tokens between transactions.
contract GXSwapRouter {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //  Immutable state
    // ---------------------------------------------------------------

    /// @notice Factory used to look up / verify pair addresses.
    GXSwapFactory public immutable factory;

    // ---------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------

    error Expired();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InsufficientOutputAmount();
    error InvalidPath();
    error InsufficientLiquidity();
    error ZeroAmount();

    // ---------------------------------------------------------------
    //  Modifiers
    // ---------------------------------------------------------------

    /// @dev Revert if the deadline has passed.
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    /// @param _factory Address of the GXSwapFactory.
    constructor(address _factory) {
        factory = GXSwapFactory(_factory);
    }

    // ---------------------------------------------------------------
    //  Internal helpers
    // ---------------------------------------------------------------

    /// @dev Sort two token addresses.
    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
    }

    /// @dev Given some amount of an asset and pair reserves, returns an
    ///      equivalent amount of the other asset (for adding liquidity).
    function _quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert ZeroAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = (amountA * reserveB) / reserveA;
    }

    /// @dev Given an input amount and pair reserves, returns the maximum
    ///      output amount after the 0.3 % fee.
    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator       = amountInWithFee * reserveOut;
        uint256 denominator     = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @dev Compute chained output amounts for a multi-hop path.
    function _getAmountsOut(uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ) {
            address pair = factory.getPair(path[i], path[i + 1]);
            (uint112 reserve0, uint112 reserve1, ) = GXSwapPair(pair).getReserves();
            (address token0, ) = _sortTokens(path[i], path[i + 1]);
            (uint256 reserveIn, uint256 reserveOut) = path[i] == token0
                ? (uint256(reserve0), uint256(reserve1))
                : (uint256(reserve1), uint256(reserve0));
            amounts[i + 1] = _getAmountOut(amounts[i], reserveIn, reserveOut);
            unchecked { ++i; }
        }
    }

    /// @dev Compute optimal liquidity amounts given desired and minimum
    ///      amounts.
    function _addLiquidityAmounts(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        address pair = factory.getPair(tokenA, tokenB);

        if (pair == address(0)) {
            // First liquidity deposit -- use desired amounts as-is.
            return (amountADesired, amountBDesired);
        }

        (uint112 reserve0, uint112 reserve1, ) = GXSwapPair(pair).getReserves();
        (address token0, ) = _sortTokens(tokenA, tokenB);
        (uint256 reserveA, uint256 reserveB) = tokenA == token0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }

        uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin) revert InsufficientBAmount();
            return (amountADesired, amountBOptimal);
        }

        uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
        assert(amountAOptimal <= amountADesired);
        if (amountAOptimal < amountAMin) revert InsufficientAAmount();
        return (amountAOptimal, amountBDesired);
    }

    // ---------------------------------------------------------------
    //  Liquidity
    // ---------------------------------------------------------------

    /// @notice Add liquidity to a pair.  Creates the pair if it does not
    ///         exist yet.
    /// @param tokenA First token.
    /// @param tokenB Second token.
    /// @param amountADesired Maximum amount of tokenA to deposit.
    /// @param amountBDesired Maximum amount of tokenB to deposit.
    /// @param amountAMin Minimum acceptable amount of tokenA.
    /// @param amountBMin Minimum acceptable amount of tokenB.
    /// @param to Recipient of the LP tokens.
    /// @param deadline Unix timestamp after which the tx reverts.
    /// @return amountA Actual tokenA deposited.
    /// @return amountB Actual tokenB deposited.
    /// @return liquidity LP tokens minted.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        // Create pair if it does not exist.
        if (factory.getPair(tokenA, tokenB) == address(0)) {
            factory.createPair(tokenA, tokenB);
        }

        (amountA, amountB) = _addLiquidityAmounts(
            tokenA, tokenB,
            amountADesired, amountBDesired,
            amountAMin, amountBMin
        );

        address pair = factory.getPair(tokenA, tokenB);
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = GXSwapPair(pair).mint(to);
    }

    /// @notice Remove liquidity from a pair.
    /// @param tokenA First token.
    /// @param tokenB Second token.
    /// @param liquidity Amount of LP tokens to burn.
    /// @param amountAMin Minimum acceptable amount of tokenA.
    /// @param amountBMin Minimum acceptable amount of tokenB.
    /// @param to Recipient of the underlying tokens.
    /// @param deadline Unix timestamp after which the tx reverts.
    /// @return amountA Actual tokenA received.
    /// @return amountB Actual tokenB received.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        address pair = factory.getPair(tokenA, tokenB);
        // Transfer LP tokens to the pair for burning.
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 amount0, uint256 amount1) = GXSwapPair(pair).burn(to);

        (address token0, ) = _sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);

        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    // ---------------------------------------------------------------
    //  Swaps
    // ---------------------------------------------------------------

    /// @notice Swap an exact input amount along a multi-hop path.
    /// @param amountIn Exact input amount of the first token in `path`.
    /// @param amountOutMin Minimum acceptable output of the last token.
    /// @param path Array of token addresses defining the swap route.
    /// @param to Recipient of the final output tokens.
    /// @param deadline Unix timestamp after which the tx reverts.
    /// @return amounts Array of amounts at each hop.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = _getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) {
            revert InsufficientOutputAmount();
        }

        // Transfer input tokens to the first pair.
        address firstPair = factory.getPair(path[0], path[1]);
        IERC20(path[0]).safeTransferFrom(msg.sender, firstPair, amounts[0]);

        // Execute chained swaps.
        _swap(amounts, path, to);
    }

    /// @dev Execute a chain of swaps.
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal {
        for (uint256 i; i < path.length - 1; ) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = _sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0
                ? (uint256(0), amountOut)
                : (amountOut, uint256(0));

            address dest = i < path.length - 2
                ? factory.getPair(output, path[i + 2])
                : _to;

            GXSwapPair(factory.getPair(input, output)).swap(
                amount0Out,
                amount1Out,
                dest
            );
            unchecked { ++i; }
        }
    }

    // ---------------------------------------------------------------
    //  View functions
    // ---------------------------------------------------------------

    /// @notice Given an input amount and a swap path, compute all
    ///         intermediate and final output amounts.
    /// @param amountIn Input amount of path[0].
    /// @param path Token addresses defining the route.
    /// @return amounts Output amounts at each step.
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        return _getAmountsOut(amountIn, path);
    }
}
