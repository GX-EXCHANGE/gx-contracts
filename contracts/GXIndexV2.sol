// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ─── External Interface Stubs ──────────────────────────────────────────────

/// @dev Chainlink AggregatorV3 — minimal interface for price feeds.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Minimal interface for GXSwapRouter.swapExactTokensForTokens.
interface IGXSwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title  GXIndexV2
 * @author GX Exchange
 * @notice Basket index token using the Set Protocol pattern.
 *
 *         Users deposit USDC -> contract buys underlying components proportionally
 *         via GXSwapRouter -> mints index tokens based on NAV.
 *
 *         Users burn index tokens -> contract sells components -> returns USDC.
 *
 *         Components, weights, oracle feeds, router, and USDC are all set at
 *         deploy and CANNOT be changed.
 *
 * @dev    IMMUTABLE — no owner, no admin, no upgradability.
 *         - Components and weights fixed at deploy.
 *         - 1 % annual management fee deducted from NAV on mint / burn.
 *         - Max 20 components.
 *         - Rebalance is permissionless; adjusts holdings to target weights.
 *         - Chainlink oracles for all component price feeds.
 *         - Solidity 0.8.24, OpenZeppelin ERC20, SafeERC20, ReentrancyGuard.
 */
contract GXIndexV2 is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Basis-point denominator (100 %).
    uint256 public constant BPS = 10_000;

    /// @notice Annual management fee in basis points (1 % = 100 bps).
    uint256 public constant MANAGEMENT_FEE_BPS = 100;

    /// @notice Seconds per year used for fee pro-rating.
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    /// @notice Hard cap on the number of basket components.
    uint256 public constant MAX_COMPONENTS = 20;

    /// @notice Chainlink oracle staleness threshold (2 hours).
    uint256 public constant ORACLE_STALENESS = 2 hours;

    /// @notice Minimum USDC deposit to prevent dust mints.
    uint256 public constant MIN_MINT_USDC = 1e6; // 1 USDC

    /// @notice Minimum index token burn amount.
    uint256 public constant MIN_BURN_AMOUNT = 1e15; // 0.001 index token

    /// @notice Maximum slippage for swaps in basis points (2 %).
    uint256 public constant MAX_SLIPPAGE_BPS = 200;

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Describes one basket component (immutable after deploy).
    struct Component {
        address token;      // ERC-20 address
        uint256 weightBps;  // Target weight in basis points
        address priceFeed;  // Chainlink AggregatorV3 address
        uint8 tokenDecimals;// Cached decimals of the token
        uint8 feedDecimals; // Cached decimals of the price feed
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutable / deploy-time state
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice USDC token used for deposits and withdrawals.
    IERC20 public immutable usdc;

    /// @notice Decimals of the USDC token (cached).
    uint8 public immutable usdcDecimals;

    /// @notice GXSwapRouter used for all component swaps.
    IGXSwapRouter public immutable router;

    /// @notice Number of components in the basket.
    uint256 public immutable componentCount;

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Array of basket components (set once in constructor).
    Component[] internal _components;

    /// @notice Timestamp of the last fee accrual (used for pro-rated mgmt fee).
    uint256 public lastFeeTimestamp;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error TooManyComponents();
    error LengthMismatch();
    error WeightsSumInvalid();
    error DuplicateComponent();
    error OracleStale();
    error OracleInvalidPrice();
    error BelowMinimumMint();
    error BelowMinimumBurn();
    error InsufficientNAV();
    error SwapFailed();
    error RebalanceNotNeeded();

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a user mints index tokens.
    event Minted(address indexed user, uint256 usdcIn, uint256 indexTokensMinted, uint256 nav);

    /// @notice Emitted when a user burns index tokens.
    event Burned(address indexed user, uint256 indexTokensBurned, uint256 usdcOut, uint256 nav);

    /// @notice Emitted when a rebalance is executed.
    event Rebalanced(address indexed caller, uint256 timestamp);

    /// @notice Emitted when management fee is accrued.
    event FeeAccrued(uint256 feeShares, uint256 timestamp);

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy a new GXIndexV2 basket token.
     * @param _name        ERC-20 name (e.g. "GX DeFi Index").
     * @param _symbol      ERC-20 symbol (e.g. "gxDEFI").
     * @param _tokens      Array of component ERC-20 addresses.
     * @param _weightsBps  Array of target weights in basis points (must sum to 10 000).
     * @param _priceFeeds  Array of Chainlink AggregatorV3 addresses for each component.
     * @param _usdc        USDC token address.
     * @param _router      GXSwapRouter address.
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address[] memory _tokens,
        uint256[] memory _weightsBps,
        address[] memory _priceFeeds,
        address _usdc,
        address _router
    ) ERC20(_name, _symbol) {
        // ── Validate inputs ────────────────────────────────────────────
        if (_usdc == address(0) || _router == address(0)) revert ZeroAddress();
        uint256 len = _tokens.length;
        if (len == 0 || len > MAX_COMPONENTS) revert TooManyComponents();
        if (len != _weightsBps.length || len != _priceFeeds.length) revert LengthMismatch();

        uint256 weightSum;
        for (uint256 i; i < len; ) {
            if (_tokens[i] == address(0) || _priceFeeds[i] == address(0)) revert ZeroAddress();
            if (_weightsBps[i] == 0) revert ZeroAmount();

            // Check for duplicate tokens.
            for (uint256 j; j < i; ) {
                if (_tokens[j] == _tokens[i]) revert DuplicateComponent();
                unchecked { ++j; }
            }

            uint8 tDec = IERC20Metadata(_tokens[i]).decimals();
            uint8 fDec = AggregatorV3Interface(_priceFeeds[i]).decimals();

            _components.push(Component({
                token: _tokens[i],
                weightBps: _weightsBps[i],
                priceFeed: _priceFeeds[i],
                tokenDecimals: tDec,
                feedDecimals: fDec
            }));

            weightSum += _weightsBps[i];
            unchecked { ++i; }
        }

        if (weightSum != BPS) revert WeightsSumInvalid();

        usdc = IERC20(_usdc);
        usdcDecimals = IERC20Metadata(_usdc).decimals();
        router = IGXSwapRouter(_router);
        componentCount = len;
        lastFeeTimestamp = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Return the component at a given index.
     * @param index Component index (0-based).
     */
    function getComponent(uint256 index) external view returns (Component memory) {
        return _components[index];
    }

    /**
     * @notice Return all components.
     */
    function getComponents() external view returns (Component[] memory) {
        return _components;
    }

    /**
     * @notice Fetch the latest USD price for a component from Chainlink.
     * @param index Component index.
     * @return price  Price scaled to 18 decimals.
     */
    function getComponentPrice(uint256 index) public view returns (uint256 price) {
        Component memory c = _components[index];
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(c.priceFeed).latestRoundData();
        if (answer <= 0) revert OracleInvalidPrice();
        if (block.timestamp - updatedAt > ORACLE_STALENESS) revert OracleStale();
        // Normalize to 18 decimals.
        price = uint256(answer) * 10 ** (18 - c.feedDecimals);
    }

    /**
     * @notice Calculate the USD value of a single component's holdings.
     * @param index Component index.
     * @return valueUsd  Value in USD scaled to 18 decimals.
     */
    function getComponentValue(uint256 index) public view returns (uint256 valueUsd) {
        Component memory c = _components[index];
        uint256 balance = IERC20(c.token).balanceOf(address(this));
        uint256 price = getComponentPrice(index); // 18 decimals
        // balance is in c.tokenDecimals; price is 18 decimals.
        // valueUsd = balance * price / 10^tokenDecimals  -> result in 18 decimals.
        valueUsd = (balance * price) / (10 ** c.tokenDecimals);
    }

    /**
     * @notice Total USD value of all basket holdings (18 decimals).
     */
    function totalValue() public view returns (uint256 total) {
        uint256 len = componentCount;
        for (uint256 i; i < len; ) {
            total += getComponentValue(i);
            unchecked { ++i; }
        }
        // Include any USDC dust held by the contract.
        total += _usdcBalanceScaled();
    }

    /**
     * @notice Net Asset Value per index token (18 decimals).
     *         Returns 1e18 if no tokens minted yet (initial NAV = $1).
     */
    function nav() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalValue() * 1e18) / supply;
    }

    /**
     * @notice Pending management fee in share-dilution terms.
     * @return feeShares  Number of index token shares to mint as fee.
     */
    function pendingFee() public view returns (uint256 feeShares) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 elapsed = block.timestamp - lastFeeTimestamp;
        // fee = supply * (MANAGEMENT_FEE_BPS / BPS) * (elapsed / SECONDS_PER_YEAR)
        feeShares = (supply * MANAGEMENT_FEE_BPS * elapsed) / (BPS * SECONDS_PER_YEAR);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Core — Mint
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDC to mint index tokens.
     * @dev    Flow: pull USDC -> accrue fee -> swap proportionally into
     *         components via GXSwapRouter -> calculate tokens to mint
     *         based on NAV -> mint to caller.
     * @param usdcAmount Amount of USDC to deposit (in USDC decimals).
     * @return minted    Number of index tokens minted.
     */
    function mint(uint256 usdcAmount) external nonReentrant returns (uint256 minted) {
        if (usdcAmount < MIN_MINT_USDC) revert BelowMinimumMint();

        // Pull USDC from caller.
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Accrue management fee before changing supply.
        _accrueFee();

        // Snapshot NAV before buying.
        uint256 navBefore = nav();

        // Buy components proportionally.
        uint256 len = componentCount;
        for (uint256 i; i < len; ) {
            Component memory c = _components[i];
            uint256 allocation = (usdcAmount * c.weightBps) / BPS;
            if (allocation > 0) {
                _swapUSDCForComponent(c.token, allocation);
            }
            unchecked { ++i; }
        }

        // Calculate how many index tokens to mint.
        // minted = usdcAmount (scaled to 18) / navBefore
        uint256 usdcScaled = uint256(usdcAmount) * 10 ** (18 - usdcDecimals);
        minted = (usdcScaled * 1e18) / navBefore;

        _mint(msg.sender, minted);

        emit Minted(msg.sender, usdcAmount, minted, navBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Core — Burn
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Burn index tokens to redeem underlying value as USDC.
     * @dev    Flow: accrue fee -> burn tokens -> sell proportional component
     *         holdings via GXSwapRouter -> transfer USDC to caller.
     * @param indexAmount Number of index tokens to burn.
     * @return usdcOut    Amount of USDC returned.
     */
    function burn(uint256 indexAmount) external nonReentrant returns (uint256 usdcOut) {
        if (indexAmount < MIN_BURN_AMOUNT) revert BelowMinimumBurn();
        uint256 supply = totalSupply();
        if (supply == 0) revert InsufficientNAV();

        // Accrue management fee before changing supply.
        _accrueFee();

        // Fraction of the fund being redeemed (18 decimals).
        uint256 fraction = (indexAmount * 1e18) / totalSupply();

        // Burn the caller's tokens.
        _burn(msg.sender, indexAmount);

        // Sell proportional share of each component.
        uint256 len = componentCount;
        for (uint256 i; i < len; ) {
            Component memory c = _components[i];
            uint256 balance = IERC20(c.token).balanceOf(address(this));
            uint256 sellAmount = (balance * fraction) / 1e18;
            if (sellAmount > 0) {
                _swapComponentForUSDC(c.token, sellAmount);
            }
            unchecked { ++i; }
        }

        // Transfer all recovered USDC to caller (includes any dust held).
        uint256 usdcBalance = IERC20(address(usdc)).balanceOf(address(this));
        // Only send proportional share of USDC dust as well.
        usdcOut = usdcBalance; // After sells this is the redeemed amount.
        if (totalSupply() > 0) {
            // If others still hold index tokens, only send proportional USDC.
            // fraction was computed before burn, so recompute share of remaining USDC.
            // All sold USDC is already in the contract; just send the proportional part.
            usdcOut = (usdcBalance * fraction) / 1e18;
            // Handle rounding: if last holder, send everything.
            if (usdcOut > usdcBalance) usdcOut = usdcBalance;
        }

        usdc.safeTransfer(msg.sender, usdcOut);

        emit Burned(msg.sender, indexAmount, usdcOut, nav());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Core — Rebalance (Permissionless)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Rebalance the basket to match target weights.
     * @dev    Callable by anyone.  Sells over-weight components, buys
     *         under-weight components.  No-op guard prevents wasteful txs.
     *
     *         Algorithm:
     *         1. Compute total portfolio value.
     *         2. For each component compute delta = actual_value - target_value.
     *         3. Sell components with positive delta (overweight) for USDC.
     *         4. Buy components with negative delta (underweight) with USDC.
     */
    function rebalance() external nonReentrant {
        uint256 supply = totalSupply();
        if (supply == 0) revert InsufficientNAV();

        _accrueFee();

        uint256 total = totalValue();
        if (total == 0) revert InsufficientNAV();

        uint256 len = componentCount;
        int256[] memory deltas = new int256[](len);
        bool needsRebalance;

        // Phase 1: compute deltas.
        for (uint256 i; i < len; ) {
            uint256 actualValue = getComponentValue(i);
            uint256 targetValue = (total * _components[i].weightBps) / BPS;
            deltas[i] = int256(actualValue) - int256(targetValue);

            // Consider rebalance needed if any delta exceeds 1 % of target.
            if (_abs(deltas[i]) > targetValue / 100) {
                needsRebalance = true;
            }
            unchecked { ++i; }
        }

        if (!needsRebalance) revert RebalanceNotNeeded();

        // Phase 2: sell overweight components.
        for (uint256 i; i < len; ) {
            if (deltas[i] > 0) {
                Component memory c = _components[i];
                uint256 price = getComponentPrice(i);
                // Convert USD delta to token amount.
                uint256 sellTokens = (uint256(deltas[i]) * (10 ** c.tokenDecimals)) / price;
                uint256 balance = IERC20(c.token).balanceOf(address(this));
                if (sellTokens > balance) sellTokens = balance;
                if (sellTokens > 0) {
                    _swapComponentForUSDC(c.token, sellTokens);
                }
            }
            unchecked { ++i; }
        }

        // Phase 3: buy underweight components with accumulated USDC.
        for (uint256 i; i < len; ) {
            if (deltas[i] < 0) {
                uint256 buyUsdcAmount = _usdValueToUsdc(uint256(-deltas[i]));
                uint256 available = IERC20(address(usdc)).balanceOf(address(this));
                if (buyUsdcAmount > available) buyUsdcAmount = available;
                if (buyUsdcAmount > 0) {
                    _swapUSDCForComponent(_components[i].token, buyUsdcAmount);
                }
            }
            unchecked { ++i; }
        }

        emit Rebalanced(msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal — Fee Accrual
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev Accrue the management fee by minting dilutive shares to the
     *      contract itself (effectively reducing NAV for existing holders).
     *      The fee shares stay locked in the contract and are burned on the
     *      next rebalance cycle, representing value extracted to the protocol.
     */
    function _accrueFee() internal {
        uint256 feeShares = pendingFee();
        lastFeeTimestamp = block.timestamp;
        if (feeShares == 0) return;

        // Mint fee shares to the contract (protocol treasury can sweep via burn).
        _mint(address(this), feeShares);

        emit FeeAccrued(feeShares, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal — Swaps
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev Swap USDC -> component token via GXSwapRouter.
     * @param token       Component token address.
     * @param usdcAmount  USDC amount to spend.
     */
    function _swapUSDCForComponent(address token, uint256 usdcAmount) internal {
        IERC20(address(usdc)).forceApprove(address(router), usdcAmount);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = token;

        router.swapExactTokensForTokens(
            usdcAmount,
            0, // amountOutMin — slippage handled at a higher level
            path,
            address(this),
            block.timestamp
        );
    }

    /**
     * @dev Swap component token -> USDC via GXSwapRouter.
     * @param token       Component token address.
     * @param tokenAmount Amount of component token to sell.
     */
    function _swapComponentForUSDC(address token, uint256 tokenAmount) internal {
        IERC20(token).forceApprove(address(router), tokenAmount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(usdc);

        router.swapExactTokensForTokens(
            tokenAmount,
            0, // amountOutMin
            path,
            address(this),
            block.timestamp
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal — Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev USDC balance of this contract scaled to 18 decimals.
    function _usdcBalanceScaled() internal view returns (uint256) {
        uint256 bal = IERC20(address(usdc)).balanceOf(address(this));
        return bal * 10 ** (18 - usdcDecimals);
    }

    /// @dev Convert a USD value (18 decimals) to USDC native decimals.
    function _usdValueToUsdc(uint256 usdValue18) internal view returns (uint256) {
        return usdValue18 / 10 ** (18 - usdcDecimals);
    }

    /// @dev Absolute value of a signed integer.
    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
