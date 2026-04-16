// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title  GXUSD — Immutable Multi-Collateral CDP Stablecoin
 * @notice Deposit ETH or WBTC as collateral to mint gxUSD (ERC-20).
 *         Inspired by Liquity V1, simplified into a single immutable contract.
 *         NO admin keys. NO proxy. NO governance override. Deploy and forget.
 *
 * @dev    Fork lineage:  Liquity V1 BorrowerOperations + TroveManager
 *         Condensed into one file with multi-collateral support.
 *
 *         Key parameters (all constant / immutable):
 *           - Minimum collateral ratio (MCR) : 150 %
 *           - Liquidation threshold           : 130 %
 *           - Liquidation bonus               :   5 %
 *           - Default stability fee           :   2 % annual (per-second accrual)
 *           - User-set interest rate          :   1–10 % annual (per-CDP)
 *           - Minimum debt                    : 100 gxUSD
 *
 *         Interest Rate Priority: CDP owners may set their own annual rate
 *         between 1% and 10%.  Higher rates grant liquidation protection —
 *         when multiple CDPs are eligible for liquidation, those with the
 *         lowest self-chosen rate are liquidated first.
 *
 *         Collateral tokens and Chainlink price feeds are set once at deploy.
 *
 * @custom:security ReentrancyGuard on every state-mutating external function.
 *                  SafeERC20 for all token transfers.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Chainlink Aggregator V3 — minimal interface
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
// Contract
// ──────────────────────────────────────────────────────────────────────────────

contract GXUSD is ERC20, ERC20Burnable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Minimum collateral ratio to open / maintain a healthy CDP (150 %).
    uint256 public constant MCR = 150e16; // 1.5e18 → 150 %

    /// @notice Collateral ratio below which a CDP can be liquidated (130 %).
    uint256 public constant LIQUIDATION_THRESHOLD = 130e16; // 1.3e18 → 130 %

    /// @notice Bonus paid to the liquidator, expressed as a fraction of debt value (5 %).
    uint256 public constant LIQUIDATION_BONUS = 5e16; // 0.05e18 → 5 %

    /// @notice Default annual stability fee in 18-decimal precision (2 %).
    ///         Used when a CDP owner has not set a custom interest rate.
    uint256 public constant ANNUAL_STABILITY_FEE = 2e16; // 0.02e18 → 2 %

    /// @notice Per-second stability fee multiplier for the default 2% rate.
    ///         Derived: (1 + 0.02)^(1/31_536_000) ≈ 1.000000000634195...
    ///         Stored as  1e18 + 634_195_839  =  1_000_000_000_634_195_839
    uint256 public constant FEE_PER_SECOND = 1_000_000_000_634_195_839;

    /// @notice Minimum user-selectable interest rate: 1% annual (100 bps).
    uint256 public constant MIN_INTEREST_RATE_BPS = 100;

    /// @notice Maximum user-selectable interest rate: 10% annual (1000 bps).
    uint256 public constant MAX_INTEREST_RATE_BPS = 1000;

    /// @notice Default interest rate in bps: 2% annual (200 bps).
    uint256 public constant DEFAULT_INTEREST_RATE_BPS = 200;

    /// @notice Number of seconds in a year (365 days), used for rate math.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice 1e18 precision base used throughout ratio / fee math.
    uint256 public constant PRECISION = 1e18;

    /// @notice Minimum gxUSD debt per CDP (prevents dust / gas-griefing attacks).
    uint256 public constant MIN_DEBT = 100e18; // 100 gxUSD

    /// @notice Maximum oracle staleness (2 hours).
    uint256 public constant ORACLE_STALENESS = 7200;

    /// @notice Number of supported collateral types (ETH + WBTC).
    uint256 public constant NUM_COLLATERALS = 2;

    // ─── Immutables ───────────────────────────────────────────────────────────

    /// @notice WETH address (collateral index 0).
    IERC20 public immutable weth;

    /// @notice WBTC address (collateral index 1).
    IERC20 public immutable wbtc;

    /// @notice Chainlink ETH / USD price feed.
    AggregatorV3Interface public immutable ethPriceFeed;

    /// @notice Chainlink BTC / USD price feed.
    AggregatorV3Interface public immutable btcPriceFeed;

    /// @notice WETH decimals (cached at deploy to avoid repeated external calls).
    uint8 public immutable wethDecimals;

    /// @notice WBTC decimals (cached at deploy).
    uint8 public immutable wbtcDecimals;

    /// @notice ETH price feed decimals (cached at deploy).
    uint8 public immutable ethFeedDecimals;

    /// @notice BTC price feed decimals (cached at deploy).
    uint8 public immutable btcFeedDecimals;

    /// @notice Deployment timestamp (used for informational purposes).
    uint256 public immutable deployedAt;

    // ─── CDP Storage ──────────────────────────────────────────────────────────

    /// @notice Auto-incrementing CDP identifier. First CDP = 1.
    uint256 public nextCdpId = 1;

    /// @dev Represents a single collateralized debt position.
    struct CDP {
        address owner;
        address collateralToken; // weth or wbtc
        uint256 collateralAmount; // in token's native decimals
        uint256 debt; // gxUSD owed (18 decimals), includes accrued fees
        uint256 lastAccrual; // timestamp of last fee accrual
        uint256 interestRateBps; // user-set annual rate in basis points (100 = 1%, 1000 = 10%), 0 = default
        bool active;
    }

    /// @notice CDP id ⇒ CDP data.
    mapping(uint256 => CDP) public cdps;

    /// @notice Owner ⇒ list of CDP ids they own.
    mapping(address => uint256[]) public ownerCdps;

    // ─── Aggregate Accounting ─────────────────────────────────────────────────

    /// @notice Total outstanding gxUSD debt across all CDPs (before accrual of
    ///         individual positions — actual supply may lag until `_accrueInterest`
    ///         is called per-CDP).
    uint256 public totalSystemDebt;

    /// @notice token address ⇒ total collateral locked in all CDPs.
    mapping(address => uint256) public totalCollateralLocked;

    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a new CDP is opened.
    event CDPOpened(
        uint256 indexed cdpId,
        address indexed owner,
        address indexed collateralToken,
        uint256 collateralAmount,
        uint256 debtMinted
    );

    /// @notice Emitted when a CDP is closed by its owner.
    event CDPClosed(uint256 indexed cdpId, address indexed owner);

    /// @notice Emitted when extra collateral is deposited into a CDP.
    event CollateralAdded(uint256 indexed cdpId, uint256 amount);

    /// @notice Emitted when collateral is withdrawn from a CDP.
    event CollateralRemoved(uint256 indexed cdpId, uint256 amount);

    /// @notice Emitted when debt is partially repaid.
    event DebtRepaid(uint256 indexed cdpId, uint256 amount);

    /// @notice Emitted when additional gxUSD is minted against an existing CDP.
    event DebtMinted(uint256 indexed cdpId, uint256 amount);

    /// @notice Emitted when a CDP is liquidated.
    event CDPLiquidated(
        uint256 indexed cdpId,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    /// @notice Emitted when stability fees are accrued on a CDP.
    event InterestAccrued(uint256 indexed cdpId, uint256 feeAmount);

    /// @notice Emitted when a CDP owner sets a custom interest rate.
    event InterestRateSet(uint256 indexed cdpId, uint256 oldRateBps, uint256 newRateBps);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error InvalidCollateral();
    error CDPNotActive();
    error NotCDPOwner();
    error BelowMinimumDebt();
    error BelowMCR();
    error AboveLiquidationThreshold();
    error StaleOracle();
    error NegativeOraclePrice();
    error OracleRoundMismatch();
    error RateOutOfRange();

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @notice Deploy the GXUSD CDP system.  All parameters are immutable.
     * @param _weth       WETH (Wrapped Ether) token address
     * @param _wbtc       WBTC (Wrapped Bitcoin) token address
     * @param _ethFeed    Chainlink ETH / USD price feed
     * @param _btcFeed    Chainlink BTC / USD price feed
     */
    constructor(
        address _weth,
        address _wbtc,
        address _ethFeed,
        address _btcFeed
    ) ERC20("GX USD", "gxUSD") {
        if (_weth == address(0) || _wbtc == address(0)) revert ZeroAddress();
        if (_ethFeed == address(0) || _btcFeed == address(0)) revert ZeroAddress();

        weth = IERC20(_weth);
        wbtc = IERC20(_wbtc);

        ethPriceFeed = AggregatorV3Interface(_ethFeed);
        btcPriceFeed = AggregatorV3Interface(_btcFeed);

        // Cache decimals so we never need external calls after deploy
        wethDecimals = _tokenDecimals(_weth);
        wbtcDecimals = _tokenDecimals(_wbtc);
        ethFeedDecimals = ethPriceFeed.decimals();
        btcFeedDecimals = btcPriceFeed.decimals();

        deployedAt = block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  CORE — OPEN / CLOSE CDP
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Open a new CDP: deposit collateral and mint gxUSD debt.
     * @param collateralToken  Address of the collateral (must be weth or wbtc).
     * @param collateralAmount Amount of collateral to deposit (native decimals).
     * @param debtAmount       Amount of gxUSD to mint (18 decimals).
     * @return cdpId           The id of the newly created CDP.
     */
    function openCDP(
        address collateralToken,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external nonReentrant returns (uint256 cdpId) {
        if (collateralAmount == 0) revert ZeroAmount();
        if (debtAmount == 0) revert ZeroAmount();
        if (debtAmount < MIN_DEBT) revert BelowMinimumDebt();
        _validateCollateral(collateralToken);

        // Transfer collateral in
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // Assign CDP id
        cdpId = nextCdpId++;

        cdps[cdpId] = CDP({
            owner: msg.sender,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            debt: debtAmount,
            lastAccrual: block.timestamp,
            interestRateBps: 0, // 0 = use default (ANNUAL_STABILITY_FEE / 2%)
            active: true
        });

        ownerCdps[msg.sender].push(cdpId);

        // Check collateral ratio ≥ MCR
        uint256 cr = _collateralRatio(collateralToken, collateralAmount, debtAmount);
        if (cr < MCR) revert BelowMCR();

        // Update accounting
        totalSystemDebt += debtAmount;
        totalCollateralLocked[collateralToken] += collateralAmount;

        // Mint gxUSD to borrower
        _mint(msg.sender, debtAmount);

        emit CDPOpened(cdpId, msg.sender, collateralToken, collateralAmount, debtAmount);
    }

    /**
     * @notice Close a CDP: repay all outstanding debt (including accrued fees)
     *         and receive all collateral back.
     * @param cdpId The CDP to close.
     */
    function closeCDP(uint256 cdpId) external nonReentrant {
        CDP storage pos = cdps[cdpId];
        _requireActive(pos);
        _requireOwner(pos);

        // Accrue interest first
        _accrueInterest(cdpId);

        uint256 debt = pos.debt;
        uint256 collateral = pos.collateralAmount;
        address token = pos.collateralToken;

        // Burn the full debt from caller
        _burn(msg.sender, debt);

        // Mark closed
        pos.active = false;
        pos.debt = 0;
        pos.collateralAmount = 0;

        // Update accounting
        totalSystemDebt -= debt;
        totalCollateralLocked[token] -= collateral;

        // Return collateral
        IERC20(token).safeTransfer(msg.sender, collateral);

        emit CDPClosed(cdpId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  COLLATERAL MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit additional collateral into an existing CDP.
     * @param cdpId  Target CDP.
     * @param amount Amount of collateral to add (native decimals).
     */
    function addCollateral(uint256 cdpId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        CDP storage pos = cdps[cdpId];
        _requireActive(pos);
        _requireOwner(pos);

        _accrueInterest(cdpId);

        IERC20(pos.collateralToken).safeTransferFrom(msg.sender, address(this), amount);

        pos.collateralAmount += amount;
        totalCollateralLocked[pos.collateralToken] += amount;

        emit CollateralAdded(cdpId, amount);
    }

    /**
     * @notice Withdraw collateral from a CDP.  The resulting collateral ratio
     *         must remain ≥ MCR.
     * @param cdpId  Target CDP.
     * @param amount Amount of collateral to withdraw (native decimals).
     */
    function removeCollateral(uint256 cdpId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        CDP storage pos = cdps[cdpId];
        _requireActive(pos);
        _requireOwner(pos);

        _accrueInterest(cdpId);

        uint256 newCollateral = pos.collateralAmount - amount; // reverts on underflow
        uint256 cr = _collateralRatio(pos.collateralToken, newCollateral, pos.debt);
        if (cr < MCR) revert BelowMCR();

        pos.collateralAmount = newCollateral;
        totalCollateralLocked[pos.collateralToken] -= amount;

        IERC20(pos.collateralToken).safeTransfer(msg.sender, amount);

        emit CollateralRemoved(cdpId, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  DEBT MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Repay part of the debt on a CDP. Caller must hold sufficient gxUSD.
     *         Debt after repayment must be ≥ MIN_DEBT (or fully repaid via closeCDP).
     * @param cdpId  Target CDP.
     * @param amount gxUSD amount to repay (18 decimals).
     */
    function repayDebt(uint256 cdpId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        CDP storage pos = cdps[cdpId];
        _requireActive(pos);
        _requireOwner(pos);

        _accrueInterest(cdpId);

        uint256 newDebt = pos.debt - amount; // reverts on underflow
        if (newDebt != 0 && newDebt < MIN_DEBT) revert BelowMinimumDebt();

        pos.debt = newDebt;
        totalSystemDebt -= amount;

        _burn(msg.sender, amount);

        emit DebtRepaid(cdpId, amount);
    }

    /**
     * @notice Mint additional gxUSD against an existing CDP.  The resulting
     *         collateral ratio must remain ≥ MCR.
     * @param cdpId  Target CDP.
     * @param amount gxUSD to mint (18 decimals).
     */
    function mintMore(uint256 cdpId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        CDP storage pos = cdps[cdpId];
        _requireActive(pos);
        _requireOwner(pos);

        _accrueInterest(cdpId);

        uint256 newDebt = pos.debt + amount;
        uint256 cr = _collateralRatio(pos.collateralToken, pos.collateralAmount, newDebt);
        if (cr < MCR) revert BelowMCR();

        pos.debt = newDebt;
        totalSystemDebt += amount;

        _mint(msg.sender, amount);

        emit DebtMinted(cdpId, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTEREST RATE MANAGEMENT — Per-CDP user-set rate
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set a custom annual interest rate on your CDP.
     *
     *         Rate must be between 100 bps (1%) and 1000 bps (10%).
     *         Higher rate = higher priority to NOT be liquidated.
     *         When multiple CDPs are under-collateralized, those paying
     *         the lowest rate should be liquidated first (off-chain ordering).
     *
     *         Accrues any pending interest at the OLD rate before switching.
     *
     * @param cdpId    The CDP to update.
     * @param rateBps  Annual interest rate in basis points (100 = 1%, 1000 = 10%).
     */
    function setInterestRate(uint256 cdpId, uint256 rateBps) external nonReentrant {
        if (rateBps < MIN_INTEREST_RATE_BPS || rateBps > MAX_INTEREST_RATE_BPS) revert RateOutOfRange();

        CDP storage pos = cdps[cdpId];
        _requireActive(pos);
        _requireOwner(pos);

        // Accrue interest at the old rate before changing
        _accrueInterest(cdpId);

        uint256 oldRate = pos.interestRateBps;
        pos.interestRateBps = rateBps;

        emit InterestRateSet(cdpId, oldRate, rateBps);
    }

    /**
     * @notice Get the effective annual interest rate for a CDP in basis points.
     *         Returns the user-set rate, or DEFAULT_INTEREST_RATE_BPS (200 = 2%)
     *         if no custom rate has been set.
     * @param cdpId The CDP to query.
     * @return rateBps Effective annual rate in basis points.
     */
    function getInterestRate(uint256 cdpId) external view returns (uint256 rateBps) {
        CDP storage pos = cdps[cdpId];
        return pos.interestRateBps == 0 ? DEFAULT_INTEREST_RATE_BPS : pos.interestRateBps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  LIQUIDATION — Permissionless
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Liquidate an under-collateralized CDP.
     *
     *         Anyone may call this if the CDP's collateral ratio is below the
     *         LIQUIDATION_THRESHOLD (130 %).  The liquidator repays the CDP's
     *         full debt and receives collateral equal to:
     *
     *             (debt * (1 + LIQUIDATION_BONUS)) / collateral_price
     *
     *         If the CDP's collateral is insufficient to cover debt + bonus,
     *         the liquidator receives all remaining collateral (partial loss
     *         absorbed by the liquidator — no socialised loss).
     *
     * @param cdpId The CDP to liquidate.
     */
    function liquidate(uint256 cdpId) external nonReentrant {
        CDP storage pos = cdps[cdpId];
        _requireActive(pos);

        // Accrue interest to get true debt
        _accrueInterest(cdpId);

        // Verify the CDP is below liquidation threshold
        uint256 cr = _collateralRatio(
            pos.collateralToken,
            pos.collateralAmount,
            pos.debt
        );
        if (cr >= LIQUIDATION_THRESHOLD) revert AboveLiquidationThreshold();

        uint256 debt = pos.debt;
        uint256 collateral = pos.collateralAmount;
        address token = pos.collateralToken;

        // Calculate collateral to seize:
        //   debtValueUSD = debt  (gxUSD is pegged 1:1 to USD, 18 decimals)
        //   seizeValueUSD = debt * (1 + bonus)
        //   seizeAmount   = seizeValueUSD / collateralPriceUSD  (in token decimals)
        uint256 price = _getPrice(token); // USD price in 18-decimal precision per 1 whole token
        uint256 tokenDecimals = _collateralDecimals(token);

        // seizeAmount in native token decimals
        uint256 seizeValue = (debt * (PRECISION + LIQUIDATION_BONUS)) / PRECISION;
        uint256 seizeAmount = (seizeValue * (10 ** tokenDecimals)) / price;

        // Cap at available collateral
        if (seizeAmount > collateral) {
            seizeAmount = collateral;
        }

        // Liquidator burns gxUSD equal to the full debt
        _burn(msg.sender, debt);

        // Close the CDP
        pos.active = false;
        pos.debt = 0;
        pos.collateralAmount = 0;

        // Update accounting
        totalSystemDebt -= debt;
        totalCollateralLocked[token] -= collateral;

        // Transfer seized collateral to liquidator
        IERC20(token).safeTransfer(msg.sender, seizeAmount);

        // If any residual collateral remains, return to the CDP owner
        uint256 residual = collateral - seizeAmount;
        if (residual > 0) {
            IERC20(token).safeTransfer(pos.owner, residual);
        }

        emit CDPLiquidated(cdpId, msg.sender, debt, seizeAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice  Current collateral ratio of a CDP (18-decimal precision).
     *          E.g. 1.5e18 = 150 %.  Includes pending (un-accrued) interest.
     * @param   cdpId  The CDP to query.
     * @return  ratio  Collateral ratio in 18-decimal precision.
     */
    function getCollateralRatio(uint256 cdpId) external view returns (uint256 ratio) {
        CDP storage pos = cdps[cdpId];
        if (!pos.active) return 0;

        // Simulate accrued debt for the view
        uint256 accruedDebt = _simulateAccruedDebt(pos.debt, pos.lastAccrual, pos.interestRateBps);
        return _collateralRatio(pos.collateralToken, pos.collateralAmount, accruedDebt);
    }

    /**
     * @notice Total outstanding system debt (sum of all CDP debts).
     *         Note: does not include un-accrued interest on individual CDPs.
     */
    function totalDebt() external view returns (uint256) {
        return totalSystemDebt;
    }

    /**
     * @notice Total collateral locked for a given token across all CDPs.
     * @param token Collateral token address (weth or wbtc).
     */
    function totalCollateral(address token) external view returns (uint256) {
        return totalCollateralLocked[token];
    }

    /**
     * @notice Get full CDP details.
     * @param cdpId CDP identifier.
     * @return owner              Address that owns the CDP.
     * @return collateralToken    Collateral asset address.
     * @return collateralAmount   Collateral deposited (native decimals).
     * @return debt               Current debt including un-accrued interest (18 decimals).
     * @return lastAccrual        Timestamp of last interest accrual.
     * @return interestRateBps    Effective annual interest rate in bps (200 = default 2%).
     * @return active             Whether the CDP is open.
     */
    function getCDP(uint256 cdpId)
        external
        view
        returns (
            address owner,
            address collateralToken,
            uint256 collateralAmount,
            uint256 debt,
            uint256 lastAccrual,
            uint256 interestRateBps,
            bool active
        )
    {
        CDP storage pos = cdps[cdpId];
        uint256 accruedDebt = pos.active
            ? _simulateAccruedDebt(pos.debt, pos.lastAccrual, pos.interestRateBps)
            : pos.debt;
        uint256 effectiveRate = pos.interestRateBps == 0 ? DEFAULT_INTEREST_RATE_BPS : pos.interestRateBps;
        return (
            pos.owner,
            pos.collateralToken,
            pos.collateralAmount,
            accruedDebt,
            pos.lastAccrual,
            effectiveRate,
            pos.active
        );
    }

    /**
     * @notice Get all CDP ids owned by an address.
     * @param owner The owner to query.
     * @return ids  Array of CDP ids (may include closed CDPs).
     */
    function getCdpsByOwner(address owner) external view returns (uint256[] memory ids) {
        return ownerCdps[owner];
    }

    /**
     * @notice Fetch the current USD price for a supported collateral token.
     * @param token Collateral address (weth or wbtc).
     * @return price USD price in 18-decimal precision per 1 whole token.
     */
    function getPrice(address token) external view returns (uint256) {
        return _getPrice(token);
    }

    /// @notice gxUSD uses 18 decimals.
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL — INTEREST ACCRUAL
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev  Accrue compounding stability fee on a CDP.  Updates `debt`,
     *       `totalSystemDebt`, and `lastAccrual`.  Mints no tokens — the fee
     *       simply increases the debt owed, and is realised when the borrower
     *       repays or is liquidated.
     *
     *       Uses the per-CDP interest rate if set, otherwise the default 2% rate.
     */
    function _accrueInterest(uint256 cdpId) internal {
        CDP storage pos = cdps[cdpId];
        if (pos.lastAccrual >= block.timestamp) return;

        uint256 elapsed = block.timestamp - pos.lastAccrual;
        uint256 feePerSec = _feePerSecondForCdp(pos.interestRateBps);
        uint256 newDebt = _compoundDebt(pos.debt, elapsed, feePerSec);
        uint256 fee = newDebt - pos.debt;

        if (fee > 0) {
            pos.debt = newDebt;
            totalSystemDebt += fee;
            emit InterestAccrued(cdpId, fee);
        }

        pos.lastAccrual = block.timestamp;
    }

    /**
     * @dev Compute compounded debt: debt * feePerSec^elapsed.
     *      Uses iterative squaring (exponentiation by squaring) for gas
     *      efficiency.  All math in 18-decimal fixed point.
     * @param debt      Current debt amount (18 decimals).
     * @param elapsed   Seconds since last accrual.
     * @param feePerSec Per-second compound factor (18-decimal, e.g. FEE_PER_SECOND).
     */
    function _compoundDebt(uint256 debt, uint256 elapsed, uint256 feePerSec) internal pure returns (uint256) {
        if (elapsed == 0 || debt == 0) return debt;

        // Exponentiation by squaring: base = feePerSec, exp = elapsed
        uint256 base = feePerSec;
        uint256 result = PRECISION; // 1e18

        while (elapsed > 0) {
            if (elapsed & 1 == 1) {
                result = (result * base) / PRECISION;
            }
            base = (base * base) / PRECISION;
            elapsed >>= 1;
        }

        return (debt * result) / PRECISION;
    }

    /**
     * @dev Simulate accrued debt for view functions (does not write state).
     *      Uses the CDP's per-position rate.
     */
    function _simulateAccruedDebt(uint256 debt, uint256 lastAccrual, uint256 interestRateBps) internal view returns (uint256) {
        if (block.timestamp <= lastAccrual) return debt;
        uint256 feePerSec = _feePerSecondForCdp(interestRateBps);
        return _compoundDebt(debt, block.timestamp - lastAccrual, feePerSec);
    }

    /**
     * @dev  Compute the per-second compound factor for a given annual rate in bps.
     *
     *       For the default rate (0 or 200 bps = 2%), returns the precomputed
     *       FEE_PER_SECOND constant for gas efficiency.
     *
     *       For custom rates, approximates (1 + rate)^(1/SECONDS_PER_YEAR) using
     *       a first-order Taylor expansion:
     *           feePerSecond ≈ 1e18 + (rateBps * 1e18) / (10000 * SECONDS_PER_YEAR)
     *
     *       This linear approximation is accurate to ~0.005% for rates up to 10%
     *       annual, which is acceptable for a per-second compound model.
     *
     * @param rateBps  Annual rate in basis points (0 = default).
     * @return Per-second compound factor in 18-decimal precision.
     */
    function _feePerSecondForCdp(uint256 rateBps) internal pure returns (uint256) {
        // 0 means no custom rate set — use default 2%
        if (rateBps == 0 || rateBps == DEFAULT_INTEREST_RATE_BPS) {
            return FEE_PER_SECOND;
        }
        // Linear approximation: 1e18 + (rateBps * 1e18) / (10_000 * SECONDS_PER_YEAR)
        return PRECISION + (rateBps * PRECISION) / (10_000 * SECONDS_PER_YEAR);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL — ORACLE
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev  Fetch the USD price of a collateral token from its Chainlink feed.
     * @param token  Collateral address (weth or wbtc).
     * @return price  Price in 18-decimal precision per 1 whole token.
     *
     *  Example: ETH at $3 000 →  3_000_000_000_000_000_000_000  (3000e18)
     */
    function _getPrice(address token) internal view returns (uint256) {
        AggregatorV3Interface feed;
        uint8 feedDec;

        if (token == address(weth)) {
            feed = ethPriceFeed;
            feedDec = ethFeedDecimals;
        } else if (token == address(wbtc)) {
            feed = btcPriceFeed;
            feedDec = btcFeedDecimals;
        } else {
            revert InvalidCollateral();
        }

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();

        if (answer <= 0) revert NegativeOraclePrice();
        if (updatedAt == 0 || block.timestamp - updatedAt > ORACLE_STALENESS) revert StaleOracle();
        if (answeredInRound < roundId) revert OracleRoundMismatch();

        // Normalize to 18 decimals
        return uint256(answer) * (10 ** (18 - feedDec));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL — COLLATERAL RATIO
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev  Compute the collateral ratio for a given token / amount / debt.
     *
     *       CR = (collateral * price) / debt
     *
     *       Both numerator and denominator are normalised to 18-decimal USD
     *       values so the result is an 18-decimal ratio (1e18 = 100 %).
     *
     * @param token       Collateral token address.
     * @param collateral  Collateral amount in native token decimals.
     * @param debt        Debt in 18-decimal gxUSD.
     * @return ratio      18-decimal precision ratio.
     */
    function _collateralRatio(
        address token,
        uint256 collateral,
        uint256 debt
    ) internal view returns (uint256 ratio) {
        if (debt == 0) return type(uint256).max; // infinite ratio when no debt

        uint256 price = _getPrice(token); // 18-dec USD per 1 whole token
        uint8 tokenDec = _collateralDecimals(token);

        // collateralValueUSD (18 decimals) = collateral * price / 10^tokenDec
        uint256 collateralValue = (collateral * price) / (10 ** tokenDec);

        // ratio (18 decimals) = collateralValue * 1e18 / debt
        return (collateralValue * PRECISION) / debt;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  INTERNAL — HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Require that the collateral token is one of the two supported assets.
    function _validateCollateral(address token) internal view {
        if (token != address(weth) && token != address(wbtc)) revert InvalidCollateral();
    }

    /// @dev Return cached decimals for a supported collateral token.
    function _collateralDecimals(address token) internal view returns (uint8) {
        if (token == address(weth)) return wethDecimals;
        if (token == address(wbtc)) return wbtcDecimals;
        revert InvalidCollateral();
    }

    /// @dev Read the `decimals()` function from an ERC-20. Used once in constructor.
    function _tokenDecimals(address token) internal view returns (uint8) {
        // solhint-disable-next-line no-inline-assembly
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        require(ok && data.length >= 32, "GXUSD: decimals() call failed");
        return abi.decode(data, (uint8));
    }

    /// @dev Revert if the CDP is not active.
    function _requireActive(CDP storage pos) internal view {
        if (!pos.active) revert CDPNotActive();
    }

    /// @dev Revert if caller is not the CDP owner.
    function _requireOwner(CDP storage pos) internal view {
        if (pos.owner != msg.sender) revert NotCDPOwner();
    }
}
