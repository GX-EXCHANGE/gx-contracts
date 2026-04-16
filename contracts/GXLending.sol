// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title GXLendToken
 * @author GX Exchange
 * @notice Receipt token minted 1:1 when users supply assets to a GXLending pool.
 *         Analogous to Aave aTokens or Compound cTokens, but with a simple 1:1
 *         exchange rate — yield is distributed via the interest index, not via
 *         rebasing supply.
 *
 * @dev Only the parent GXLending contract can mint/burn. IMMUTABLE — no owner,
 *      no admin, no upgrades.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Custom errors
// ──────────────────────────────────────────────────────────────────────────────

error OnlyLendingPool();

contract GXLendToken is ERC20 {
    /// @notice The GXLending pool that controls minting and burning.
    address public immutable lendingPool;

    /// @param _name   Token name (e.g. "GX Lend USDC")
    /// @param _symbol Token symbol (e.g. "gxUSDC")
    /// @param _pool   Address of the GXLending contract
    constructor(
        string memory _name,
        string memory _symbol,
        address _pool
    ) ERC20(_name, _symbol) {
        lendingPool = _pool;
    }

    /// @notice Mint receipt tokens. Only callable by the lending pool.
    /// @param _to     Recipient address
    /// @param _amount Amount to mint
    function mint(address _to, uint256 _amount) external {
        if (msg.sender != lendingPool) revert OnlyLendingPool();
        _mint(_to, _amount);
    }

    /// @notice Burn receipt tokens. Only callable by the lending pool.
    /// @param _from   Address to burn from
    /// @param _amount Amount to burn
    function burn(address _from, uint256 _amount) external {
        if (msg.sender != lendingPool) revert OnlyLendingPool();
        _burn(_from, _amount);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Chainlink oracle interface (minimal)
// ──────────────────────────────────────────────────────────────────────────────

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

// ──────────────────────────────────────────────────────────────────────────────
// Main imports
// ──────────────────────────────────────────────────────────────────────────────

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Custom errors
// ──────────────────────────────────────────────────────────────────────────────

error ZeroAmount();
error ZeroAddress();
error InsufficientLiquidity();
error InsufficientCollateral();
error HealthFactorAboveThreshold();
error HealthFactorBelowMinimum();
error NoBorrowToRepay();
error StaleOraclePrice();
error NegativeOraclePrice();
error BorrowCapExceeded();
error ExceedsSupplied();

/**
 * @title GXLending
 * @author GX Exchange — inspired by Aave V3 / Compound V3 lending patterns
 * @notice A single-asset lending pool. Deploy one instance per supported token
 *         (e.g. USDC, WETH, WBTC). Users supply tokens and receive gxTokens as
 *         receipt. Supplied tokens can be used as collateral to borrow from the
 *         same pool.
 *
 *         Interest model (linear):
 *           Borrow APR = BASE_RATE + (utilization × SLOPE)
 *                      = 2% + (U × 20%)
 *           Supply APR = Borrow APR × utilization
 *
 *         Health factor:
 *           HF = (collateral_value × LTV) / debt_value
 *           Liquidation triggers when HF < 1.0 (1e18 precision)
 *
 * @dev IMMUTABLE — no proxy, no admin, no owner, no upgrades.
 *      All parameters are set at deploy time and cannot be changed.
 *      Uses compound-style interest index for accurate per-second accrual.
 */
contract GXLending is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ======================================================================
       CONSTANTS
       ====================================================================== */

    /// @notice Precision for rates, health factors, and index math (1e18 = 1.0).
    uint256 public constant PRECISION = 1e18;

    /// @notice Precision for basis-point parameters (10000 = 100%).
    uint256 public constant BPS = 10_000;

    /// @notice Base borrow rate: 2% annualised (in 1e18 precision).
    uint256 public constant BASE_RATE = 0.02e18;

    /// @notice Slope of the utilization curve: 20% annualised (in 1e18 precision).
    uint256 public constant SLOPE = 0.20e18;

    /// @notice Seconds in a 365-day year for rate conversion.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Liquidation bonus in basis points (5% = 500 bps).
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;

    /// @notice Maximum oracle staleness allowed (1 hour).
    uint256 public constant ORACLE_STALENESS = 1 hours;

    /// @notice Health factor threshold below which a position is liquidatable (1.0).
    uint256 public constant HEALTH_FACTOR_THRESHOLD = 1e18;

    /* ======================================================================
       IMMUTABLE STATE (set once in constructor)
       ====================================================================== */

    /// @notice The underlying ERC-20 token for this pool (e.g. USDC, WETH, WBTC).
    IERC20 public immutable underlyingToken;

    /// @notice The receipt token minted on supply (GXLendToken).
    GXLendToken public immutable gxToken;

    /// @notice Chainlink price feed for the underlying asset (USD denominated).
    AggregatorV3Interface public immutable oracle;

    /// @notice Number of decimals of the underlying token.
    uint8 public immutable tokenDecimals;

    /// @notice Loan-to-Value ratio in basis points (e.g. 8000 = 80%).
    uint256 public immutable ltvBps;

    /// @notice Maximum total borrows allowed (denominated in underlying token).
    uint256 public immutable borrowCap;

    /* ======================================================================
       STORAGE — Interest accrual
       ====================================================================== */

    /// @notice Cumulative borrow interest index (starts at 1e18).
    uint256 public borrowIndex;

    /// @notice Cumulative supply interest index (starts at 1e18).
    uint256 public supplyIndex;

    /// @notice Last timestamp at which interest was accrued.
    uint256 public lastAccrualTime;

    /// @notice Total borrows outstanding (in underlying token, scaled by borrowIndex).
    uint256 public totalBorrows;

    /// @notice Total underlying reserves held by the pool.
    uint256 public totalReserves;

    /* ======================================================================
       STORAGE — Per-user accounting
       ====================================================================== */

    /// @notice Borrow principal per user (scaled — multiply by borrowIndex to get actual debt).
    mapping(address => uint256) public userBorrowShares;

    /// @notice Total borrow shares outstanding.
    uint256 public totalBorrowShares;

    /// @notice Snapshot of the supply index at the time of the user's last interaction.
    mapping(address => uint256) public userSupplyIndexSnapshot;

    /// @notice Snapshot of the borrow index at the time of the user's last interaction.
    mapping(address => uint256) public userBorrowIndexSnapshot;

    /* ======================================================================
       EVENTS
       ====================================================================== */

    /// @notice Emitted when a user supplies underlying tokens.
    event Supplied(address indexed user, uint256 amount, uint256 gxTokensMinted);

    /// @notice Emitted when a user withdraws underlying tokens.
    event Withdrawn(address indexed user, uint256 amount, uint256 gxTokensBurned);

    /// @notice Emitted when a user borrows underlying tokens.
    event Borrowed(address indexed user, uint256 amount, uint256 borrowShares);

    /// @notice Emitted when a user repays borrowed tokens.
    event Repaid(address indexed user, uint256 amount, uint256 borrowSharesReduced);

    /// @notice Emitted when a liquidator liquidates an under-collateralised borrower.
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    /// @notice Emitted when interest is accrued.
    event InterestAccrued(
        uint256 borrowIndex,
        uint256 supplyIndex,
        uint256 totalBorrows,
        uint256 timestamp
    );

    /* ======================================================================
       CONSTRUCTOR
       ====================================================================== */

    /**
     * @param _underlying    Address of the ERC-20 underlying token.
     * @param _oracle        Chainlink AggregatorV3 price feed (USD denominated).
     * @param _tokenDecimals Decimals of the underlying token (6 for USDC, 18 for WETH, 8 for WBTC).
     * @param _ltvBps        Loan-to-value ratio in basis points (8000 = 80%).
     * @param _borrowCap     Maximum total borrows in underlying token units.
     * @param _gxTokenName   Name for the receipt token (e.g. "GX Lend USDC").
     * @param _gxTokenSymbol Symbol for the receipt token (e.g. "gxUSDC").
     */
    constructor(
        address _underlying,
        address _oracle,
        uint8 _tokenDecimals,
        uint256 _ltvBps,
        uint256 _borrowCap,
        string memory _gxTokenName,
        string memory _gxTokenSymbol
    ) {
        if (_underlying == address(0)) revert ZeroAddress();
        if (_oracle == address(0)) revert ZeroAddress();

        underlyingToken = IERC20(_underlying);
        oracle = AggregatorV3Interface(_oracle);
        tokenDecimals = _tokenDecimals;
        ltvBps = _ltvBps;
        borrowCap = _borrowCap;

        // Deploy the receipt token — this contract is the sole minter/burner.
        gxToken = new GXLendToken(_gxTokenName, _gxTokenSymbol, address(this));

        // Initialise interest indices.
        borrowIndex = PRECISION;
        supplyIndex = PRECISION;
        lastAccrualTime = block.timestamp;
    }

    /* ======================================================================
       CORE — Supply / Withdraw
       ====================================================================== */

    /**
     * @notice Deposit underlying tokens into the pool and receive gxTokens.
     * @param _amount Amount of underlying tokens to deposit.
     */
    function supply(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        _accrueInterest();

        // Transfer underlying from user.
        underlyingToken.safeTransferFrom(msg.sender, address(this), _amount);
        totalReserves += _amount;

        // Mint receipt tokens 1:1.
        gxToken.mint(msg.sender, _amount);

        // Snapshot index for future interest calculation.
        userSupplyIndexSnapshot[msg.sender] = supplyIndex;

        emit Supplied(msg.sender, _amount, _amount);
    }

    /**
     * @notice Withdraw underlying tokens by burning gxTokens.
     * @param _amount Amount of underlying tokens to withdraw.
     */
    function withdraw(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        _accrueInterest();

        uint256 gxBalance = gxToken.balanceOf(msg.sender);
        if (_amount > gxBalance) revert ExceedsSupplied();

        // Ensure withdrawal doesn't break health factor if user has borrows.
        if (userBorrowShares[msg.sender] > 0) {
            uint256 collateralAfter = gxBalance - _amount;
            uint256 debt = _userDebt(msg.sender);
            uint256 hf = _computeHealthFactor(collateralAfter, debt);
            if (hf < HEALTH_FACTOR_THRESHOLD) revert HealthFactorBelowMinimum();
        }

        // Check pool liquidity.
        uint256 available = _availableLiquidity();
        if (_amount > available) revert InsufficientLiquidity();

        // Burn receipt tokens.
        gxToken.burn(msg.sender, _amount);
        totalReserves -= _amount;

        // Transfer underlying to user.
        underlyingToken.safeTransfer(msg.sender, _amount);

        emit Withdrawn(msg.sender, _amount, _amount);
    }

    /* ======================================================================
       CORE — Borrow / Repay
       ====================================================================== */

    /**
     * @notice Borrow underlying tokens against supplied collateral.
     * @param _amount Amount of underlying tokens to borrow.
     */
    function borrow(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        _accrueInterest();

        // Check borrow cap.
        if (totalBorrows + _amount > borrowCap) revert BorrowCapExceeded();

        // Check pool liquidity.
        if (_amount > _availableLiquidity()) revert InsufficientLiquidity();

        // Calculate new debt and verify health factor.
        uint256 currentDebt = _userDebt(msg.sender);
        uint256 newDebt = currentDebt + _amount;
        uint256 collateral = gxToken.balanceOf(msg.sender);
        uint256 hf = _computeHealthFactor(collateral, newDebt);
        if (hf < HEALTH_FACTOR_THRESHOLD) revert InsufficientCollateral();

        // Issue borrow shares.
        uint256 shares;
        if (totalBorrowShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount * totalBorrowShares) / totalBorrows;
        }

        userBorrowShares[msg.sender] += shares;
        totalBorrowShares += shares;
        totalBorrows += _amount;
        totalReserves -= _amount;

        // Snapshot borrow index.
        userBorrowIndexSnapshot[msg.sender] = borrowIndex;

        // Transfer underlying to borrower.
        underlyingToken.safeTransfer(msg.sender, _amount);

        emit Borrowed(msg.sender, _amount, shares);
    }

    /**
     * @notice Repay borrowed tokens (partial or full).
     * @param _amount Amount of underlying tokens to repay. Pass type(uint256).max
     *                to repay entire debt.
     */
    function repay(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        _accrueInterest();

        uint256 debt = _userDebt(msg.sender);
        if (debt == 0) revert NoBorrowToRepay();

        // Cap repayment at total debt.
        uint256 repayAmount = _amount > debt ? debt : _amount;

        // Calculate shares to remove.
        uint256 sharesToRemove;
        if (repayAmount == debt) {
            sharesToRemove = userBorrowShares[msg.sender];
        } else {
            sharesToRemove = (repayAmount * totalBorrowShares) / totalBorrows;
            // Ensure at least 1 share is removed to prevent dust.
            if (sharesToRemove == 0) sharesToRemove = 1;
        }

        // Transfer underlying from user.
        underlyingToken.safeTransferFrom(msg.sender, address(this), repayAmount);

        // Update state.
        userBorrowShares[msg.sender] -= sharesToRemove;
        totalBorrowShares -= sharesToRemove;
        totalBorrows -= repayAmount;
        totalReserves += repayAmount;

        // Update snapshot.
        userBorrowIndexSnapshot[msg.sender] = borrowIndex;

        emit Repaid(msg.sender, repayAmount, sharesToRemove);
    }

    /* ======================================================================
       CORE — Liquidation
       ====================================================================== */

    /**
     * @notice Liquidate an under-collateralised borrower. The liquidator repays
     *         the borrower's entire debt and receives their collateral (gxTokens)
     *         plus a 5% liquidation bonus.
     *
     * @dev Anyone can call this when the borrower's health factor < 1.0.
     *      The liquidator must have approved this contract for the repay amount.
     *
     * @param _borrower Address of the borrower to liquidate.
     */
    function liquidate(address _borrower) external nonReentrant {
        if (_borrower == address(0)) revert ZeroAddress();

        _accrueInterest();

        uint256 debt = _userDebt(_borrower);
        if (debt == 0) revert NoBorrowToRepay();

        uint256 collateral = gxToken.balanceOf(_borrower);
        uint256 hf = _computeHealthFactor(collateral, debt);
        if (hf >= HEALTH_FACTOR_THRESHOLD) revert HealthFactorAboveThreshold();

        // Calculate collateral to seize: debt value + 5% bonus, converted to token units.
        uint256 debtValue = _tokenToUsd(debt);
        uint256 seizeValue = (debtValue * (BPS + LIQUIDATION_BONUS_BPS)) / BPS;
        uint256 seizeAmount = _usdToToken(seizeValue);

        // Cap seize at borrower's total collateral.
        if (seizeAmount > collateral) {
            seizeAmount = collateral;
        }

        // Liquidator repays the borrower's debt.
        underlyingToken.safeTransferFrom(msg.sender, address(this), debt);

        // Clear borrower's debt.
        uint256 borrowerShares = userBorrowShares[_borrower];
        totalBorrowShares -= borrowerShares;
        totalBorrows -= debt;
        totalReserves += debt;
        userBorrowShares[_borrower] = 0;
        userBorrowIndexSnapshot[_borrower] = borrowIndex;

        // Transfer collateral (gxTokens) from borrower to liquidator.
        gxToken.burn(_borrower, seizeAmount);
        gxToken.mint(msg.sender, seizeAmount);

        // Reduce pool reserves to reflect the collateral transfer.
        // (gxTokens still represent claims on the pool, just a different holder.)

        emit Liquidated(msg.sender, _borrower, debt, seizeAmount);
    }

    /* ======================================================================
       INTEREST ACCRUAL
       ====================================================================== */

    /**
     * @notice Accrue interest based on time elapsed since last accrual.
     *         Updates both borrow and supply indices.
     * @dev Called internally before every state-changing operation.
     */
    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        if (elapsed == 0) return;

        lastAccrualTime = block.timestamp;

        if (totalBorrows == 0) return;

        // Calculate utilisation rate.
        uint256 util = _utilization();

        // Borrow rate per second.
        uint256 borrowRateAnnual = BASE_RATE + ((util * SLOPE) / PRECISION);
        uint256 borrowRatePerSec = borrowRateAnnual / SECONDS_PER_YEAR;

        // Interest accrued this period.
        uint256 interestFactor = borrowRatePerSec * elapsed;
        uint256 interestAccrued = (totalBorrows * interestFactor) / PRECISION;

        // Update borrow index.
        borrowIndex += (borrowIndex * interestFactor) / PRECISION;

        // Update total borrows.
        totalBorrows += interestAccrued;
        totalReserves += interestAccrued;

        // Supply index grows proportionally: supply rate = borrow rate * utilization.
        uint256 supplyInterest = (interestAccrued * PRECISION) / totalReserves;
        supplyIndex += (supplyIndex * supplyInterest) / PRECISION;

        emit InterestAccrued(borrowIndex, supplyIndex, totalBorrows, block.timestamp);
    }

    /**
     * @notice Public function to trigger interest accrual (permissionless).
     */
    function accrueInterest() external {
        _accrueInterest();
    }

    /* ======================================================================
       VIEW FUNCTIONS
       ====================================================================== */

    /**
     * @notice Current utilisation rate of the pool.
     * @return Utilization as a fraction with 1e18 precision (e.g. 0.5e18 = 50%).
     */
    function _utilization() internal view returns (uint256) {
        if (totalReserves == 0) return 0;
        return (totalBorrows * PRECISION) / totalReserves;
    }

    /// @notice Public view for current utilisation rate.
    function utilization() external view returns (uint256) {
        return _utilization();
    }

    /**
     * @notice Current annualised borrow APR.
     * @return Annual borrow rate with 1e18 precision (e.g. 0.12e18 = 12%).
     */
    function borrowAPR() external view returns (uint256) {
        uint256 u = _utilization();
        return BASE_RATE + ((u * SLOPE) / PRECISION);
    }

    /**
     * @notice Current annualised supply APR.
     * @return Annual supply rate with 1e18 precision.
     */
    function supplyAPR() external view returns (uint256) {
        uint256 u = _utilization();
        uint256 bRate = BASE_RATE + ((u * SLOPE) / PRECISION);
        return (bRate * u) / PRECISION;
    }

    /**
     * @notice Actual debt owed by a user (principal + accrued interest).
     * @param _user Address of the borrower.
     * @return Total debt in underlying token units.
     */
    function userDebt(address _user) external view returns (uint256) {
        return _userDebt(_user);
    }

    /**
     * @notice Health factor of a user's position.
     * @param _user Address of the user.
     * @return Health factor with 1e18 precision. Returns type(uint256).max if
     *         the user has no debt.
     */
    function healthFactor(address _user) external view returns (uint256) {
        uint256 debt = _userDebt(_user);
        if (debt == 0) return type(uint256).max;
        uint256 collateral = gxToken.balanceOf(_user);
        return _computeHealthFactor(collateral, debt);
    }

    /// @notice Available liquidity in the pool for borrowing/withdrawals.
    function availableLiquidity() external view returns (uint256) {
        return _availableLiquidity();
    }

    /// @notice Current price of the underlying token in USD (8-decimal precision from Chainlink).
    function getPrice() external view returns (uint256) {
        return _getPrice();
    }

    /* ======================================================================
       INTERNAL HELPERS
       ====================================================================== */

    /// @dev Returns actual debt for a user based on their borrow shares.
    function _userDebt(address _user) internal view returns (uint256) {
        uint256 shares = userBorrowShares[_user];
        if (shares == 0 || totalBorrowShares == 0) return 0;
        return (shares * totalBorrows) / totalBorrowShares;
    }

    /// @dev Available liquidity = total reserves - total borrows (tokens actually in pool).
    function _availableLiquidity() internal view returns (uint256) {
        uint256 balance = underlyingToken.balanceOf(address(this));
        return balance;
    }

    /**
     * @dev Compute health factor:
     *      HF = (collateral_value_usd × LTV) / debt_value_usd
     *
     * @param _collateralTokens Collateral in underlying token units.
     * @param _debtTokens       Debt in underlying token units.
     * @return Health factor with 1e18 precision.
     */
    function _computeHealthFactor(
        uint256 _collateralTokens,
        uint256 _debtTokens
    ) internal view returns (uint256) {
        if (_debtTokens == 0) return type(uint256).max;

        uint256 collateralUsd = _tokenToUsd(_collateralTokens);
        uint256 debtUsd = _tokenToUsd(_debtTokens);

        // collateral adjusted by LTV.
        uint256 adjustedCollateral = (collateralUsd * ltvBps) / BPS;

        return (adjustedCollateral * PRECISION) / debtUsd;
    }

    /**
     * @dev Convert token amount to USD value (18-decimal precision).
     * @param _tokenAmount Amount in underlying token units.
     * @return USD value with 18-decimal precision.
     */
    function _tokenToUsd(uint256 _tokenAmount) internal view returns (uint256) {
        uint256 price = _getPrice(); // 8 decimals from Chainlink.
        // Normalise to 18 decimals: amount * price / 10^tokenDecimals * 10^18 / 10^8.
        return (_tokenAmount * price * 1e10) / (10 ** tokenDecimals);
    }

    /**
     * @dev Convert USD value (18-decimal precision) to token amount.
     * @param _usdValue USD value with 18-decimal precision.
     * @return Token amount in underlying token units.
     */
    function _usdToToken(uint256 _usdValue) internal view returns (uint256) {
        uint256 price = _getPrice(); // 8 decimals.
        // Inverse of _tokenToUsd.
        return (_usdValue * (10 ** tokenDecimals)) / (price * 1e10);
    }

    /**
     * @dev Fetch latest price from Chainlink oracle with staleness check.
     * @return Price with 8-decimal precision.
     */
    function _getPrice() internal view returns (uint256) {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,

        ) = oracle.latestRoundData();

        if (answer <= 0) revert NegativeOraclePrice();
        if (block.timestamp - updatedAt > ORACLE_STALENESS) revert StaleOraclePrice();

        return uint256(answer);
    }
}
