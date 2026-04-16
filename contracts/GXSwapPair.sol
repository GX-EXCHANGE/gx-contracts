// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GXSwapPair
/// @author GX Exchange
/// @notice Constant-product AMM pair (x * y = k) inspired by Uniswap V2.
/// @dev IMMUTABLE -- no owner, no admin functions, no upgradability.
///      Each pair holds exactly two ERC-20 tokens and mints LP tokens to
///      liquidity providers.  A 0.3 % swap fee is hard-coded.
contract GXSwapPair is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //  Constants
    // ---------------------------------------------------------------

    /// @notice Minimum liquidity permanently locked on first deposit to
    ///         prevent the first-depositor inflation attack.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Swap fee numerator (3 / 1000 = 0.3 %).
    uint256 private constant FEE_NUMERATOR = 997;

    /// @notice Swap fee denominator.
    uint256 private constant FEE_DENOMINATOR = 1000;

    // ---------------------------------------------------------------
    //  Immutable state
    // ---------------------------------------------------------------

    /// @notice Factory that deployed this pair.
    address public immutable factory;

    /// @notice First token in the pair (sorted by address).
    address public immutable token0;

    /// @notice Second token in the pair (sorted by address).
    address public immutable token1;

    // ---------------------------------------------------------------
    //  Reserves & oracle
    // ---------------------------------------------------------------

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32  private _blockTimestampLast;

    /// @notice Cumulative price of token0 denominated in token1 (UQ112x112).
    uint256 public price0CumulativeLast;

    /// @notice Cumulative price of token1 denominated in token0 (UQ112x112).
    uint256 public price1CumulativeLast;

    /// @notice k after the most recent liquidity event (reserve0 * reserve1).
    uint256 public kLast;

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    /// @notice Emitted when liquidity is added.
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);

    /// @notice Emitted when liquidity is removed.
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);

    /// @notice Emitted on every swap.
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    /// @notice Emitted when reserves are synced.
    event Sync(uint112 reserve0, uint112 reserve1);

    // ---------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------

    error Forbidden();
    error Overflow();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error KInvariantViolated();

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    /// @notice Deployed by the factory.  Token addresses are set once and
    ///         cannot be changed.
    /// @param _token0 Address of the lower-sorted token.
    /// @param _token1 Address of the higher-sorted token.
    constructor(address _token0, address _token1)
        ERC20("GX Swap LP", "GX-LP")
    {
        factory = msg.sender;
        token0  = _token0;
        token1  = _token1;
    }

    // ---------------------------------------------------------------
    //  View helpers
    // ---------------------------------------------------------------

    /// @notice Returns current reserves and the last block timestamp.
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    {
        reserve0           = _reserve0;
        reserve1           = _reserve1;
        blockTimestampLast = _blockTimestampLast;
    }

    // ---------------------------------------------------------------
    //  Internal helpers
    // ---------------------------------------------------------------

    /// @dev Update reserves and, on the first call of each block, accumulate
    ///      price data for the TWAP oracle.
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 reserve0_,
        uint112 reserve1_
    ) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) {
            revert Overflow();
        }

        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        unchecked {
            uint32 timeElapsed = blockTimestamp - _blockTimestampLast;
            if (timeElapsed > 0 && reserve0_ != 0 && reserve1_ != 0) {
                // UQ112x112 price accumulators -- overflow is desired.
                price0CumulativeLast += uint256(
                    (uint224(reserve1_) << 112) / reserve0_
                ) * timeElapsed;
                price1CumulativeLast += uint256(
                    (uint224(reserve0_) << 112) / reserve1_
                ) * timeElapsed;
            }
        }

        _reserve0           = uint112(balance0);
        _reserve1           = uint112(balance1);
        _blockTimestampLast = blockTimestamp;

        emit Sync(uint112(balance0), uint112(balance1));
    }

    // ---------------------------------------------------------------
    //  Mint (add liquidity)
    // ---------------------------------------------------------------

    /// @notice Mint LP tokens to `to` after the caller has transferred
    ///         the desired token amounts into the pair.
    /// @param to Recipient of the LP tokens.
    /// @return liquidity Amount of LP tokens minted.
    function mint(address to) external nonReentrant returns (uint256 liquidity) {
        (uint112 reserve0_, uint112 reserve1_, ) = this.getReserves();

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0  = balance0 - reserve0_;
        uint256 amount1  = balance1 - reserve1_;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            // Permanently lock the first MINIMUM_LIQUIDITY tokens to
            // address(0) -- prevents totalSupply from ever reaching zero
            // after the initial deposit and mitigates the inflation attack.
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(
                (amount0 * _totalSupply) / reserve0_,
                (amount1 * _totalSupply) / reserve1_
            );
        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);
        _update(balance0, balance1, reserve0_, reserve1_);
        kLast = uint256(_reserve0) * _reserve1;

        emit Mint(msg.sender, amount0, amount1);
    }

    // ---------------------------------------------------------------
    //  Burn (remove liquidity)
    // ---------------------------------------------------------------

    /// @notice Burn LP tokens held by this contract and send underlying
    ///         tokens to `to`.
    /// @param to Recipient of the underlying tokens.
    /// @return amount0 Amount of token0 returned.
    /// @return amount1 Amount of token1 returned.
    function burn(address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        (uint112 reserve0_, uint112 reserve1_, ) = this.getReserves();

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1, reserve0_, reserve1_);
        kLast = uint256(_reserve0) * _reserve1;

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // ---------------------------------------------------------------
    //  Swap
    // ---------------------------------------------------------------

    /// @notice Swap tokens.  At least one of `amount0Out` / `amount1Out`
    ///         must be > 0.  The caller must have already transferred
    ///         sufficient input tokens to satisfy the 0.3 % fee-inclusive
    ///         constant-product invariant.
    /// @param amount0Out Desired output of token0.
    /// @param amount1Out Desired output of token1.
    /// @param to Recipient of the output tokens.
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external nonReentrant {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();

        (uint112 reserve0_, uint112 reserve1_, ) = this.getReserves();
        if (amount0Out >= reserve0_ || amount1Out >= reserve1_) {
            revert InsufficientLiquidity();
        }
        if (to == token0 || to == token1) revert InvalidTo();

        // Optimistic transfer
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // Compute input amounts
        uint256 amount0In = balance0 > reserve0_ - amount0Out
            ? balance0 - (reserve0_ - amount0Out)
            : 0;
        uint256 amount1In = balance1 > reserve1_ - amount1Out
            ? balance1 - (reserve1_ - amount1Out)
            : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // Verify k invariant with fee (0.3 %)
        {
            uint256 balance0Adjusted = (balance0 * FEE_DENOMINATOR) - (amount0In * (FEE_DENOMINATOR - FEE_NUMERATOR));
            uint256 balance1Adjusted = (balance1 * FEE_DENOMINATOR) - (amount1In * (FEE_DENOMINATOR - FEE_NUMERATOR));
            if (
                balance0Adjusted * balance1Adjusted <
                uint256(reserve0_) * uint256(reserve1_) * (FEE_DENOMINATOR ** 2)
            ) {
                revert KInvariantViolated();
            }
        }

        _update(balance0, balance1, reserve0_, reserve1_);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // ---------------------------------------------------------------
    //  Force-sync
    // ---------------------------------------------------------------

    /// @notice Force reserves to match current balances.
    function sync() external nonReentrant {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            _reserve0,
            _reserve1
        );
    }
}
