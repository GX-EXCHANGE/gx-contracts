// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GXStablecoin (gxUSD) — Yield-bearing stablecoin backed by USDC
/// @notice Deposit USDC → mint gxUSD at current exchange rate. Yield accrues
///         as the exchange rate increases (wstETH model). Underlying USDC is
///         deployed to a GXYieldVault for yield generation.
/// @dev 6 decimals (matches USDC). Exchange rate starts at 1:1 and only grows.
contract GXStablecoin is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── State ──────────────────────────────────────────────────────

    /// Underlying USDC token
    IERC20 public immutable usdc;

    /// Yield vault where USDC is deployed for yield
    address public yieldVault;

    /// Precision for exchange rate math (1e6 = 1.000000)
    uint256 private constant RATE_PRECISION = 1e6;

    // ─── Events ─────────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 usdcAmount, uint256 gxusdMinted);
    event Withdrawn(address indexed user, uint256 gxusdBurned, uint256 usdcReturned);
    event YieldVaultUpdated(address indexed oldVault, address indexed newVault);

    // ─── Errors ─────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error NoYieldVault();
    error InsufficientBalance();

    // ─── Constructor ────────────────────────────────────────────────

    /// @param _usdc USDC token address (e.g., Arbitrum USDC)
    constructor(address _usdc)
        ERC20("gxUSD", "gxUSD")
        Ownable(msg.sender)
    {
        if (_usdc == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
    }

    // ─── Core ───────────────────────────────────────────────────────

    /// @notice Deposit USDC and receive gxUSD at the current exchange rate.
    /// @param usdcAmount Amount of USDC to deposit (6 decimals)
    function deposit(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();

        uint256 gxusdToMint = _usdcToGxusd(usdcAmount);

        // Pull USDC from sender
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Forward USDC to yield vault if set
        if (yieldVault != address(0)) {
            usdc.safeTransfer(yieldVault, usdcAmount);
        }

        _mint(msg.sender, gxusdToMint);
        emit Deposited(msg.sender, usdcAmount, gxusdToMint);
    }

    /// @notice Burn gxUSD and receive USDC at the current exchange rate.
    /// @param gxusdAmount Amount of gxUSD to burn
    function withdraw(uint256 gxusdAmount) external nonReentrant {
        if (gxusdAmount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < gxusdAmount) revert InsufficientBalance();

        uint256 usdcToReturn = _gxusdToUsdc(gxusdAmount);

        _burn(msg.sender, gxusdAmount);

        // Pull from yield vault if needed
        uint256 localBalance = usdc.balanceOf(address(this));
        if (localBalance < usdcToReturn && yieldVault != address(0)) {
            uint256 shortfall = usdcToReturn - localBalance;
            usdc.safeTransferFrom(yieldVault, address(this), shortfall);
        }

        usdc.safeTransfer(msg.sender, usdcToReturn);
        emit Withdrawn(msg.sender, gxusdAmount, usdcToReturn);
    }

    // ─── View ───────────────────────────────────────────────────────

    /// @notice Current exchange rate: USDC per 1 gxUSD (6-decimal precision).
    ///         Starts at 1_000_000 (1:1) and increases as yield accrues.
    /// @return rate USDC amount per 1 gxUSD (scaled by 1e6)
    function exchangeRate() public view returns (uint256 rate) {
        uint256 supply = totalSupply();
        if (supply == 0) return RATE_PRECISION; // 1:1 when no supply
        return (totalAssets() * RATE_PRECISION) / supply;
    }

    /// @notice Total USDC backing all gxUSD (this contract + yield vault).
    function totalAssets() public view returns (uint256) {
        uint256 local = usdc.balanceOf(address(this));
        if (yieldVault != address(0)) {
            local += usdc.balanceOf(yieldVault);
        }
        return local;
    }

    /// @notice gxUSD uses 6 decimals (matches USDC).
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ─── Admin ──────────────────────────────────────────────────────

    /// @notice Set or update the yield vault address.
    /// @param _yieldVault New yield vault address
    function setYieldVault(address _yieldVault) external onlyOwner {
        if (_yieldVault == address(0)) revert ZeroAddress();
        emit YieldVaultUpdated(yieldVault, _yieldVault);
        yieldVault = _yieldVault;
    }

    // ─── Internal ───────────────────────────────────────────────────

    /// @dev Convert USDC amount → gxUSD amount at current rate.
    function _usdcToGxusd(uint256 usdcAmount) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return usdcAmount; // 1:1 initially
        return (usdcAmount * supply) / totalAssets();
    }

    /// @dev Convert gxUSD amount → USDC amount at current rate.
    function _gxusdToUsdc(uint256 gxusdAmount) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return gxusdAmount; // 1:1 initially
        return (gxusdAmount * totalAssets()) / supply;
    }
}
