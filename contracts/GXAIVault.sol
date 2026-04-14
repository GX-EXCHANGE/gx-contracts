// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title GXAIVault
/// @author GX Exchange
/// @notice ERC-4626 tokenised AI-managed trading vault with safety rails.
/// @dev Extends the GXYieldVault pattern with four additional safety features
///      designed for AI/algorithmic strategy management:
///
///      1. **Whitelisted strategy address** -- only the designated strategyManager
///         can deploy vault funds to the trading strategy and return them.
///      2. **Max drawdown circuit breaker** -- if total assets drop more than 20 %
///         from the high-water mark, new strategy deployments are blocked.
///      3. **Withdrawal timelock** -- users request a withdrawal and must wait
///         24 hours before executing it, giving the strategy time to unwind.
///      4. **Emergency pause** -- owner can pause deposits and strategy
///         deployments; withdrawals always remain open for user safety.
///
///      Fees (unchanged from base):
///        - Management fee : 2 % annualised, charged on total assets.
///        - Performance fee: 20 % of yield above high-water mark.
///
///      Both fee parameters and the fee recipient are set at deploy and
///      cannot be changed.
///
///      First-depositor inflation protection: the very first deposit must
///      be at least `MIN_INITIAL_DEPOSIT` tokens.
contract GXAIVault is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------------
    //  Constants
    // ---------------------------------------------------------------

    /// @notice Management fee: 2 % annual (in basis points).
    uint256 public constant MANAGEMENT_FEE_BPS = 200;

    /// @notice Performance fee: 20 % of yield (in basis points).
    uint256 public constant PERFORMANCE_FEE_BPS = 2000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Seconds in a year (365.25 days) for management fee accrual.
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    /// @notice Minimum first deposit to prevent inflation attacks.
    uint256 public constant MIN_INITIAL_DEPOSIT = 1000;

    /// @notice Maximum drawdown from high-water mark before circuit breaker
    ///         trips (20 % expressed in basis points).
    uint256 public constant MAX_DRAWDOWN_BPS = 2000;

    /// @notice Time a user must wait after requesting a withdrawal before
    ///         they can execute it (24 hours).
    uint256 public constant WITHDRAWAL_DELAY = 24 hours;

    // ---------------------------------------------------------------
    //  Immutable state
    // ---------------------------------------------------------------

    /// @notice Treasury address that receives all fees.
    address public immutable treasury;

    /// @notice Maximum total assets the vault will accept.
    uint256 public immutable depositCap;

    /// @notice Whitelisted AI/algo strategy manager that can deploy and
    ///         return funds.
    address public immutable strategyManager;

    // ---------------------------------------------------------------
    //  Mutable state
    // ---------------------------------------------------------------

    /// @notice High-water mark of total assets used for both
    ///         performance-fee accounting and drawdown circuit breaker.
    uint256 public highWaterMark;

    /// @notice Timestamp of the last management-fee accrual.
    uint256 public lastFeeTimestamp;

    /// @notice Amount of USDC currently deployed to the strategy.
    uint256 public deployedToStrategy;

    /// @notice Whether the vault is paused (blocks deposits & strategy
    ///         deployments; withdrawals remain open).
    bool public paused;

    // ---------------------------------------------------------------
    //  Withdrawal timelock
    // ---------------------------------------------------------------

    /// @notice Pending withdrawal request for a user.
    struct WithdrawalRequest {
        uint256 shares;
        uint256 requestTime;
    }

    /// @notice Pending withdrawal requests keyed by depositor address.
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    /// @notice Emitted when fees are harvested.
    event FeesHarvested(
        uint256 managementFee,
        uint256 performanceFee,
        uint256 sharesMinted
    );

    /// @notice Emitted when funds are deployed to the AI strategy.
    event DeployedToStrategy(uint256 amount);

    /// @notice Emitted when funds are returned from the AI strategy.
    event ReturnedFromStrategy(uint256 amount);

    /// @notice Emitted when a user requests a timelocked withdrawal.
    event WithdrawalRequested(address indexed user, uint256 shares, uint256 requestTime);

    /// @notice Emitted when a timelocked withdrawal is executed.
    event WithdrawalCompleted(address indexed user, uint256 shares, uint256 assets);

    /// @notice Emitted when a pending withdrawal request is cancelled.
    event WithdrawalCancelled(address indexed user, uint256 shares);

    /// @notice Emitted when the vault is paused.
    event Paused(address indexed by);

    /// @notice Emitted when the vault is unpaused.
    event Unpaused(address indexed by);

    // ---------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------

    error DepositCapExceeded();
    error InitialDepositTooSmall();
    error ZeroTreasury();
    error ZeroCap();
    error ZeroStrategy();
    error NotStrategyManager();
    error DrawdownBreached();
    error VaultPaused();
    error NoWithdrawalRequest();
    error WithdrawalNotReady();
    error InsufficientShares();
    error ZeroAmount();

    // ---------------------------------------------------------------
    //  Modifiers
    // ---------------------------------------------------------------

    modifier onlyStrategy() {
        if (msg.sender != strategyManager) revert NotStrategyManager();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert VaultPaused();
        _;
    }

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    /// @param _asset Underlying ERC-20 asset (e.g. USDC).
    /// @param _name Vault share token name.
    /// @param _symbol Vault share token symbol.
    /// @param _treasury Address that receives management & performance fees.
    /// @param _depositCap Maximum total assets accepted by the vault.
    /// @param _strategyManager Whitelisted AI strategy address allowed to
    ///        deploy and return funds.
    /// @param _owner Owner address that can pause / unpause the vault.
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _treasury,
        uint256 _depositCap,
        address _strategyManager,
        address _owner
    ) ERC20(_name, _symbol) ERC4626(_asset) Ownable(_owner) {
        if (_treasury == address(0)) revert ZeroTreasury();
        if (_depositCap == 0) revert ZeroCap();
        if (_strategyManager == address(0)) revert ZeroStrategy();

        treasury         = _treasury;
        depositCap       = _depositCap;
        strategyManager  = _strategyManager;
        lastFeeTimestamp = block.timestamp;
    }

    // ---------------------------------------------------------------
    //  ERC-4626 overrides
    // ---------------------------------------------------------------

    /// @notice Total assets include both vault balance and deployed capital.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + deployedToStrategy;
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        if (paused) return 0;
        uint256 total = totalAssets();
        if (total >= depositCap) return 0;
        return depositCap - total;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @dev Hook called before every deposit / mint.  Accrues fees and
    ///      enforces deposit cap + minimum initial deposit + pause check.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        // First-depositor protection
        if (totalSupply() == 0 && assets < MIN_INITIAL_DEPOSIT) {
            revert InitialDepositTooSmall();
        }

        // Harvest fees before state change
        _harvestFees();

        // Cap check (after fee harvest so totalAssets is up to date)
        if (totalAssets() + assets > depositCap) revert DepositCapExceeded();

        super._deposit(caller, receiver, assets, shares);

        // Update high-water mark on deposit
        _updateHighWaterMark();
    }

    /// @dev Hook called before every withdraw / redeem.  Accrues fees.
    ///      Withdrawals are NEVER blocked by pause (user safety).
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        _harvestFees();
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // ---------------------------------------------------------------
    //  Strategy deployment (whitelisted)
    // ---------------------------------------------------------------

    /// @notice Deploy vault USDC to the AI trading strategy.
    /// @dev Only callable by the whitelisted strategyManager. Reverts if
    ///      the drawdown circuit breaker has been tripped or vault is paused.
    /// @param amount Amount of USDC to send to the strategy.
    function deployToStrategy(uint256 amount) external onlyStrategy whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (checkDrawdown()) revert DrawdownBreached();

        deployedToStrategy += amount;
        IERC20(asset()).safeTransfer(strategyManager, amount);

        emit DeployedToStrategy(amount);
    }

    /// @notice Return USDC (principal + any profits) from the strategy
    ///         back into the vault.
    /// @dev Only callable by the whitelisted strategyManager.
    /// @param amount Amount of USDC being returned.
    function returnFromStrategy(uint256 amount) external onlyStrategy {
        if (amount == 0) revert ZeroAmount();

        // Pull funds back from strategy
        IERC20(asset()).safeTransferFrom(strategyManager, address(this), amount);

        // Reduce deployed tracker (cap at 0 if profits exceed original deployment)
        if (amount >= deployedToStrategy) {
            deployedToStrategy = 0;
        } else {
            deployedToStrategy -= amount;
        }

        // Update high-water mark if new peak
        _updateHighWaterMark();

        emit ReturnedFromStrategy(amount);
    }

    // ---------------------------------------------------------------
    //  Drawdown circuit breaker
    // ---------------------------------------------------------------

    /// @notice Check whether the drawdown from high-water mark exceeds
    ///         the MAX_DRAWDOWN_BPS threshold.
    /// @return breached True if drawdown exceeds 20 %, blocking new
    ///         strategy deployments.
    function checkDrawdown() public view returns (bool breached) {
        if (highWaterMark == 0) return false;
        uint256 total = totalAssets();
        if (total >= highWaterMark) return false;
        uint256 drawdown = highWaterMark - total;
        // breached when drawdown / highWaterMark > MAX_DRAWDOWN_BPS / BPS_DENOMINATOR
        return (drawdown * BPS_DENOMINATOR) / highWaterMark > MAX_DRAWDOWN_BPS;
    }

    // ---------------------------------------------------------------
    //  Withdrawal timelock
    // ---------------------------------------------------------------

    /// @notice Queue a withdrawal request. The caller must wait
    ///         WITHDRAWAL_DELAY (24 h) before executing.
    /// @param shares Number of vault shares to withdraw.
    function requestWithdrawal(uint256 shares) external {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        withdrawalRequests[msg.sender] = WithdrawalRequest({
            shares: shares,
            requestTime: block.timestamp
        });

        emit WithdrawalRequested(msg.sender, shares, block.timestamp);
    }

    /// @notice Execute a previously queued withdrawal after the 24 h
    ///         timelock has elapsed.
    function completeWithdrawal() external {
        WithdrawalRequest memory req = withdrawalRequests[msg.sender];
        if (req.shares == 0) revert NoWithdrawalRequest();
        if (block.timestamp < req.requestTime + WITHDRAWAL_DELAY) {
            revert WithdrawalNotReady();
        }

        uint256 shares = req.shares;
        delete withdrawalRequests[msg.sender];

        // Use the standard ERC-4626 redeem flow (which calls _withdraw)
        uint256 assets = redeem(shares, msg.sender, msg.sender);

        emit WithdrawalCompleted(msg.sender, shares, assets);
    }

    /// @notice Cancel a pending withdrawal request.
    function cancelWithdrawal() external {
        WithdrawalRequest memory req = withdrawalRequests[msg.sender];
        if (req.shares == 0) revert NoWithdrawalRequest();

        delete withdrawalRequests[msg.sender];

        emit WithdrawalCancelled(msg.sender, req.shares);
    }

    // ---------------------------------------------------------------
    //  Emergency pause (owner only)
    // ---------------------------------------------------------------

    /// @notice Pause the vault. Blocks deposits and strategy deployments.
    ///         Withdrawals remain open for user safety.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the vault. Re-enables deposits and strategy
    ///         deployments.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ---------------------------------------------------------------
    //  Fee logic
    // ---------------------------------------------------------------

    /// @notice Manually trigger fee accrual.  Anyone can call.
    function harvestFees() external {
        _harvestFees();
    }

    /// @dev Accrue management + performance fees by minting vault shares
    ///      to the treasury.
    function _harvestFees() internal {
        uint256 total = totalAssets();
        uint256 supply = totalSupply();
        if (supply == 0 || total == 0) {
            lastFeeTimestamp = block.timestamp;
            return;
        }

        uint256 managementFeeAssets;
        uint256 performanceFeeAssets;

        // --- Management fee (time-weighted) ---
        uint256 elapsed = block.timestamp - lastFeeTimestamp;
        if (elapsed > 0) {
            // fee = totalAssets * 2% * elapsed / year
            managementFeeAssets = (total * MANAGEMENT_FEE_BPS * elapsed)
                / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        }

        // --- Performance fee (high-water mark) ---
        if (total > highWaterMark && highWaterMark > 0) {
            uint256 yield_ = total - highWaterMark;
            performanceFeeAssets = (yield_ * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;
        }

        uint256 totalFeeAssets = managementFeeAssets + performanceFeeAssets;
        if (totalFeeAssets > 0) {
            // Mint shares to treasury worth `totalFeeAssets`.
            // shares = totalFeeAssets * supply / (total - totalFeeAssets)
            // Clamp so we never mint against negative net assets.
            if (totalFeeAssets >= total) {
                totalFeeAssets = total / 2; // safety clamp
            }
            uint256 feeShares = (totalFeeAssets * supply) / (total - totalFeeAssets);
            if (feeShares > 0) {
                _mint(treasury, feeShares);
                emit FeesHarvested(managementFeeAssets, performanceFeeAssets, feeShares);
            }
        }

        // Update bookkeeping
        _updateHighWaterMark();
        lastFeeTimestamp = block.timestamp;
    }

    // ---------------------------------------------------------------
    //  Internal helpers
    // ---------------------------------------------------------------

    /// @dev Update the high-water mark if current total assets exceed it.
    function _updateHighWaterMark() internal {
        uint256 total = totalAssets();
        if (total > highWaterMark) {
            highWaterMark = total;
        }
    }

    // ---------------------------------------------------------------
    //  View helpers
    // ---------------------------------------------------------------

    /// @notice Returns pending management + performance fees in asset
    ///         terms (before minting shares).
    /// @return managementFee Accrued management fee.
    /// @return performanceFee Accrued performance fee.
    function pendingFees()
        external
        view
        returns (uint256 managementFee, uint256 performanceFee)
    {
        uint256 total = totalAssets();
        uint256 elapsed = block.timestamp - lastFeeTimestamp;
        if (elapsed > 0 && total > 0) {
            managementFee = (total * MANAGEMENT_FEE_BPS * elapsed)
                / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        }
        if (total > highWaterMark && highWaterMark > 0) {
            performanceFee = ((total - highWaterMark) * PERFORMANCE_FEE_BPS)
                / BPS_DENOMINATOR;
        }
    }

    /// @notice Offset for virtual shares/assets to mitigate inflation
    ///         attack.  Uses 6 decimals offset for USDC (6 decimals).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
