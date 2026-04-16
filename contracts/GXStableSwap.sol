// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GXStableSwap
/// @author GX Exchange
/// @notice Two-token StableSwap AMM implementing Curve's invariant for
///         tightly-pegged assets (e.g. gxUSD/USDC, gxUSD/USDT).
/// @dev IMMUTABLE -- no owner, no admin functions, no upgradability.
///
///      The StableSwap invariant interpolates between the constant-sum
///      (x + y = D) and constant-product (x * y = (D/2)^2) curves using
///      an amplification coefficient A:
///
///          A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
///
///      For n = 2 tokens.
///
///      Fee: 0.04 % per swap, hard-coded.
///      LP token: built-in ERC-20.
contract GXStableSwap is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------
    //  Constants
    // ---------------------------------------------------------------

    /// @notice Number of tokens in the pool.
    uint256 private constant N_COINS = 2;

    /// @notice Precision used for internal math (1e18).
    uint256 private constant PRECISION = 1e18;

    /// @notice Swap fee: 4 / 10_000 = 0.04 %.
    uint256 public constant FEE = 4e14; // 0.04% in 1e18 basis

    /// @notice Fee denominator.
    uint256 public constant FEE_DENOMINATOR = 1e18;

    /// @notice Max iterations for Newton's method convergence.
    uint256 private constant MAX_ITER = 256;

    // ---------------------------------------------------------------
    //  Immutable state
    // ---------------------------------------------------------------

    /// @notice First token (index 0).
    address public immutable token0;

    /// @notice Second token (index 1).
    address public immutable token1;

    /// @notice Decimal multiplier to normalise token0 to 18 decimals.
    uint256 public immutable precision0;

    /// @notice Decimal multiplier to normalise token1 to 18 decimals.
    uint256 public immutable precision1;

    /// @notice Amplification coefficient (A * n^n), set at deploy.
    uint256 public immutable A;

    // ---------------------------------------------------------------
    //  Mutable state
    // ---------------------------------------------------------------

    /// @notice Pool balances in native token decimals.
    uint256[2] public balances;

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    /// @notice Emitted on a token exchange.
    event TokenExchange(
        address indexed buyer,
        uint256 soldId,
        uint256 tokensSold,
        uint256 boughtId,
        uint256 tokensBought
    );

    /// @notice Emitted when liquidity is added.
    event AddLiquidity(
        address indexed provider,
        uint256[2] tokenAmounts,
        uint256 mintAmount
    );

    /// @notice Emitted when liquidity is removed proportionally.
    event RemoveLiquidity(
        address indexed provider,
        uint256[2] tokenAmounts,
        uint256 burnAmount
    );

    /// @notice Emitted when liquidity is removed in a single token.
    event RemoveLiquidityOne(
        address indexed provider,
        uint256 tokenIndex,
        uint256 tokenAmount,
        uint256 burnAmount
    );

    // ---------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------

    error InvalidIndex();
    error SameIndex();
    error ZeroAmount();
    error SlippageExceeded();
    error InvariantNotConverged();
    error YNotConverged();
    error InsufficientBalance();

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    /// @param _token0 Address of the first stablecoin.
    /// @param _token1 Address of the second stablecoin.
    /// @param _A Amplification coefficient (A * n^n).  Typical values:
    ///           100 - 1000 for tightly pegged assets.
    constructor(
        address _token0,
        address _token1,
        uint256 _A
    ) ERC20("GX StableSwap LP", "gxSS-LP") {
        token0 = _token0;
        token1 = _token1;
        A      = _A;

        uint8 d0 = IERC20Metadata(_token0).decimals();
        uint8 d1 = IERC20Metadata(_token1).decimals();
        precision0 = 10 ** (18 - d0);
        precision1 = 10 ** (18 - d1);
    }

    // ---------------------------------------------------------------
    //  Internal math -- StableSwap invariant
    // ---------------------------------------------------------------

    /// @dev Returns balances scaled to 18 decimals.
    function _xp() internal view returns (uint256[2] memory xp) {
        xp[0] = balances[0] * precision0;
        xp[1] = balances[1] * precision1;
    }

    /// @dev Returns given balances scaled to 18 decimals.
    function _xpMem(uint256[2] memory _balances)
        internal
        view
        returns (uint256[2] memory xp)
    {
        xp[0] = _balances[0] * precision0;
        xp[1] = _balances[1] * precision1;
    }

    /// @dev Compute D -- the StableSwap invariant -- using Newton's method.
    ///      A_nn = A * n^n (the amplification parameter stored).
    ///
    ///      Equation solved:
    ///        A_nn * S + D = A_nn * D + D^3 / (4 * x0 * x1)
    ///
    ///      Newton iteration:
    ///        D_next = (A_nn * S + 2 * D_P) * D / ((A_nn - 1) * D + 3 * D_P)
    ///
    ///      where S = x0 + x1,  D_P = D^3 / (4 * x0 * x1).
    function _getD(uint256[2] memory xp) internal view returns (uint256) {
        uint256 S = xp[0] + xp[1];
        if (S == 0) return 0;

        uint256 Ann = A * N_COINS; // A * n^n * n (for formula alignment)
        uint256 D = S;

        for (uint256 i; i < MAX_ITER; ) {
            // D_P = D^3 / (n^n * prod(x_i)) = D * D / (2*x0) * D / (2*x1)
            uint256 D_P = D;
            D_P = (D_P * D) / (xp[0] * 2 + 1); // +1 to avoid div-by-0
            D_P = (D_P * D) / (xp[1] * 2 + 1);

            uint256 D_prev = D;
            // D = (Ann * S + N_COINS * D_P) * D / ((Ann - 1) * D + (N_COINS + 1) * D_P)
            D = ((Ann * S / PRECISION + N_COINS * D_P) * D)
                / ((Ann - PRECISION) * D / PRECISION + (N_COINS + 1) * D_P);

            // Check convergence
            if (_absDiff(D, D_prev) <= 1) return D;

            unchecked { ++i; }
        }
        revert InvariantNotConverged();
    }

    /// @dev Given the invariant D and the balance of one token, compute
    ///      the balance of the other token.
    ///      Solves:  A_nn * (x + y) + D = A_nn * D + D^3 / (4*x*y)
    ///      for y, given x (and D).
    function _getY(
        uint256 i,
        uint256 j,
        uint256 x,
        uint256[2] memory xp
    ) internal view returns (uint256) {
        if (i == j) revert SameIndex();
        if (i > 1 || j > 1) revert InvalidIndex();

        uint256 D   = _getD(xp);
        uint256 Ann = A * N_COINS;

        // c = D^3 / (Ann * n^n * x)   -- simplified for 2 tokens
        uint256 c = (D * D) / (x * 2);
        c = (c * D * PRECISION) / (Ann * 2);

        // b = x + D * PRECISION / Ann
        uint256 b = x + (D * PRECISION / Ann);

        // Newton's method to find y
        uint256 y = D;
        for (uint256 k; k < MAX_ITER; ) {
            uint256 y_prev = y;
            y = (y * y + c) / (2 * y + b - D);
            if (_absDiff(y, y_prev) <= 1) return y;
            unchecked { ++k; }
        }
        revert YNotConverged();
    }

    /// @dev Absolute difference.
    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    // ---------------------------------------------------------------
    //  Exchange
    // ---------------------------------------------------------------

    /// @notice Swap token `i` for token `j`.
    /// @param i Index of the input token (0 or 1).
    /// @param j Index of the output token (0 or 1).
    /// @param dx Amount of token `i` to sell (in native decimals).
    /// @param minDy Minimum amount of token `j` to receive.
    /// @return dy Amount of token `j` received.
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minDy
    ) external nonReentrant returns (uint256 dy) {
        if (i > 1 || j > 1) revert InvalidIndex();
        if (i == j) revert SameIndex();
        if (dx == 0) revert ZeroAmount();

        uint256[2] memory xp = _xp();
        uint256 precisionI = i == 0 ? precision0 : precision1;
        uint256 precisionJ = j == 0 ? precision0 : precision1;

        // x_new = x_old + dx (scaled)
        uint256 x = xp[i] + dx * precisionI;
        uint256 y = _getY(i, j, x, xp);
        // dy (scaled) = y_old - y_new - 1 (rounding safety)
        uint256 dyScaled = xp[j] - y - 1;

        // Apply fee
        uint256 fee = dyScaled * FEE / FEE_DENOMINATOR;
        dyScaled -= fee;

        // Convert back to native decimals
        dy = dyScaled / precisionJ;
        if (dy < minDy) revert SlippageExceeded();

        // Transfer tokens
        address tokenIn  = i == 0 ? token0 : token1;
        address tokenOut = j == 0 ? token0 : token1;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), dx);
        IERC20(tokenOut).safeTransfer(msg.sender, dy);

        // Update balances
        balances[i] += dx;
        balances[j] -= dy;

        emit TokenExchange(msg.sender, i, dx, j, dy);
    }

    // ---------------------------------------------------------------
    //  Liquidity management
    // ---------------------------------------------------------------

    /// @notice Deposit tokens and mint LP tokens.  Either or both amounts
    ///         can be non-zero (imbalanced deposits are allowed with a
    ///         fee applied).
    /// @param amounts Amounts of [token0, token1] to deposit.
    /// @param minMintAmount Minimum LP tokens to receive.
    /// @return mintAmount LP tokens minted.
    function addLiquidity(uint256[2] calldata amounts, uint256 minMintAmount)
        external
        nonReentrant
        returns (uint256 mintAmount)
    {
        uint256 _totalSupply = totalSupply();
        uint256 D0;
        if (_totalSupply > 0) {
            D0 = _getD(_xp());
        }

        uint256[2] memory newBalances;
        newBalances[0] = balances[0] + amounts[0];
        newBalances[1] = balances[1] + amounts[1];

        uint256 D1 = _getD(_xpMem(newBalances));
        if (D1 <= D0) revert ZeroAmount();

        if (_totalSupply == 0) {
            mintAmount = D1; // Initial deposit -- LP tokens = D
        } else {
            // Charge fee on imbalanced deposits.
            uint256[2] memory fees;
            for (uint256 k; k < N_COINS; ) {
                uint256 idealBalance = (D1 * balances[k]) / D0;
                uint256 diff = _absDiff(idealBalance, newBalances[k]);
                fees[k] = (FEE * diff) / FEE_DENOMINATOR;
                newBalances[k] -= fees[k]; // fee stays in pool
                unchecked { ++k; }
            }
            uint256 D2 = _getD(_xpMem(newBalances));
            mintAmount = (_totalSupply * (D2 - D0)) / D0;
        }

        if (mintAmount < minMintAmount) revert SlippageExceeded();

        // Transfer tokens in
        if (amounts[0] > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amounts[0]);
        }
        if (amounts[1] > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amounts[1]);
        }

        // Update balances (use amounts, not newBalances which has fees deducted)
        balances[0] += amounts[0];
        balances[1] += amounts[1];

        _mint(msg.sender, mintAmount);

        emit AddLiquidity(msg.sender, amounts, mintAmount);
    }

    /// @notice Remove liquidity proportionally.
    /// @param amount LP tokens to burn.
    /// @param minAmounts Minimum amounts of [token0, token1] to receive.
    /// @return amounts Actual amounts withdrawn.
    function removeLiquidity(uint256 amount, uint256[2] calldata minAmounts)
        external
        nonReentrant
        returns (uint256[2] memory amounts)
    {
        uint256 _totalSupply = totalSupply();

        for (uint256 k; k < N_COINS; ) {
            amounts[k] = (balances[k] * amount) / _totalSupply;
            if (amounts[k] < minAmounts[k]) revert SlippageExceeded();
            unchecked { ++k; }
        }

        _burn(msg.sender, amount);

        // Transfer tokens out & update balances
        if (amounts[0] > 0) {
            balances[0] -= amounts[0];
            IERC20(token0).safeTransfer(msg.sender, amounts[0]);
        }
        if (amounts[1] > 0) {
            balances[1] -= amounts[1];
            IERC20(token1).safeTransfer(msg.sender, amounts[1]);
        }

        emit RemoveLiquidity(msg.sender, amounts, amount);
    }

    /// @notice Remove liquidity in a single token.
    /// @param amount LP tokens to burn.
    /// @param i Index of the token to withdraw (0 or 1).
    /// @param minAmount Minimum amount of token `i` to receive.
    /// @return dy Amount of token `i` received.
    function removeLiquidityOneCoin(
        uint256 amount,
        uint256 i,
        uint256 minAmount
    ) external nonReentrant returns (uint256 dy) {
        if (i > 1) revert InvalidIndex();

        uint256 _totalSupply = totalSupply();
        uint256[2] memory xp = _xp();
        uint256 D0 = _getD(xp);
        uint256 D1 = D0 - (D0 * amount) / _totalSupply;

        // Compute the new balance for the other token
        uint256 j = i == 0 ? 1 : 0;
        uint256 precisionI = i == 0 ? precision0 : precision1;

        // New y for token j after reducing D
        uint256 newY = _getYD(i, j, D1, xp);
        uint256 dyScaled = xp[i] - _getYD(j, i, D1, xp); // amount of token i freed

        // Apply fee
        uint256 fee = dyScaled * FEE / FEE_DENOMINATOR;
        dy = (dyScaled - fee) / precisionI;

        if (dy < minAmount) revert SlippageExceeded();

        _burn(msg.sender, amount);
        balances[i] -= dy;

        address tokenOut = i == 0 ? token0 : token1;
        IERC20(tokenOut).safeTransfer(msg.sender, dy);

        // Suppress unused variable warning
        newY;

        emit RemoveLiquidityOne(msg.sender, i, dy, amount);
    }

    /// @dev Compute y given D (for remove_liquidity_one_coin).
    ///      Similar to _getY but uses a specified D instead of computing it.
    function _getYD(
        uint256 i,
        uint256 j,
        uint256 D,
        uint256[2] memory xp
    ) internal view returns (uint256) {
        if (i == j) revert SameIndex();
        if (i > 1 || j > 1) revert InvalidIndex();

        uint256 Ann = A * N_COINS;
        uint256 x = xp[i]; // the known balance

        // c = D^3 / (Ann * n^n * x)
        uint256 c = (D * D) / (x * 2);
        c = (c * D * PRECISION) / (Ann * 2);

        // b = x + D * PRECISION / Ann
        uint256 b = x + (D * PRECISION / Ann);

        uint256 y = D;
        for (uint256 k; k < MAX_ITER; ) {
            uint256 y_prev = y;
            y = (y * y + c) / (2 * y + b - D);
            if (_absDiff(y, y_prev) <= 1) return y;
            unchecked { ++k; }
        }
        revert YNotConverged();
    }

    // ---------------------------------------------------------------
    //  View helpers
    // ---------------------------------------------------------------

    /// @notice Preview the output amount for a swap.
    /// @param i Input token index.
    /// @param j Output token index.
    /// @param dx Input amount (native decimals).
    /// @return dy Output amount (native decimals).
    function getDy(uint256 i, uint256 j, uint256 dx)
        external
        view
        returns (uint256 dy)
    {
        uint256[2] memory xp = _xp();
        uint256 precisionI = i == 0 ? precision0 : precision1;
        uint256 precisionJ = j == 0 ? precision0 : precision1;

        uint256 x = xp[i] + dx * precisionI;
        uint256 y = _getY(i, j, x, xp);
        uint256 dyScaled = xp[j] - y - 1;
        uint256 fee = dyScaled * FEE / FEE_DENOMINATOR;
        dy = (dyScaled - fee) / precisionJ;
    }

    /// @notice Returns the current virtual price of 1 LP token in units
    ///         of the pool's invariant D, scaled to 1e18.
    function getVirtualPrice() external view returns (uint256) {
        uint256 D = _getD(_xp());
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return PRECISION;
        return (D * PRECISION) / _totalSupply;
    }
}
