// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GXYieldVault
/// @author GX Exchange
/// @notice ERC-4626 tokenised yield vault with hard-coded fee structure.
/// @dev IMMUTABLE -- no owner, no admin functions, no upgradability.
///
///      Fees:
///        - Management fee : 2 % annualised, charged on total assets.
///        - Performance fee: 20 % of yield above high-water mark.
///
///      Both fee parameters and the fee recipient are set at deploy and
///      cannot be changed.
///
///      First-depositor inflation protection: the very first deposit must
///      be at least `MIN_INITIAL_DEPOSIT` tokens.
///
///      Users can always withdraw -- there is no lock period.
contract GXYieldVault is ERC4626, ReentrancyGuard {
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

    // ---------------------------------------------------------------
    //  Immutable state
    // ---------------------------------------------------------------

    /// @notice Treasury address that receives all fees.
    address public immutable treasury;

    /// @notice Maximum total assets the vault will accept.
    uint256 public immutable depositCap;

    // ---------------------------------------------------------------
    //  Mutable state
    // ---------------------------------------------------------------

    /// @notice High-water mark of total assets for performance-fee
    ///         accounting (set to totalAssets after each fee harvest).
    uint256 public highWaterMark;

    /// @notice Timestamp of the last management-fee accrual.
    uint256 public lastFeeTimestamp;

    // ---------------------------------------------------------------
    //  Events
    // ---------------------------------------------------------------

    /// @notice Emitted when fees are harvested.
    event FeesHarvested(
        uint256 managementFee,
        uint256 performanceFee,
        uint256 sharesMinted
    );

    // ---------------------------------------------------------------
    //  Errors
    // ---------------------------------------------------------------

    error DepositCapExceeded();
    error InitialDepositTooSmall();
    error ZeroTreasury();
    error ZeroCap();

    // ---------------------------------------------------------------
    //  Constructor
    // ---------------------------------------------------------------

    /// @param _asset Underlying ERC-20 asset (e.g. USDC).
    /// @param _name Vault share token name.
    /// @param _symbol Vault share token symbol.
    /// @param _treasury Address that receives management & performance fees.
    /// @param _depositCap Maximum total assets accepted by the vault.
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _treasury,
        uint256 _depositCap
    ) ERC20(_name, _symbol) ERC4626(_asset) {
        if (_treasury == address(0)) revert ZeroTreasury();
        if (_depositCap == 0) revert ZeroCap();

        treasury         = _treasury;
        depositCap       = _depositCap;
        lastFeeTimestamp  = block.timestamp;
    }

    // ---------------------------------------------------------------
    //  ERC-4626 overrides
    // ---------------------------------------------------------------

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        uint256 total = totalAssets();
        if (total >= depositCap) return 0;
        return depositCap - total;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @dev Hook called before every deposit / mint.  Accrues fees and
    ///      enforces deposit cap + minimum initial deposit.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        // First-depositor protection
        if (totalSupply() == 0 && assets < MIN_INITIAL_DEPOSIT) {
            revert InitialDepositTooSmall();
        }

        // Harvest fees before state change
        _harvestFees();

        // Cap check (after fee harvest so totalAssets is up to date)
        if (totalAssets() + assets > depositCap) revert DepositCapExceeded();

        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Hook called before every withdraw / redeem.  Accrues fees.
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
        highWaterMark    = totalAssets(); // after mint, includes dilution
        lastFeeTimestamp = block.timestamp;
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
