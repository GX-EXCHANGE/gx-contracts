// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title GXTokenSale
 * @author GX Exchange
 * @notice Fixed-price token sale contract for GX Exchange fair launch.
 *         Users send USDC or USDT and receive GX at a fixed rate.
 *         Owner can pause, withdraw funds, and recover remaining GX.
 *
 *         SIMPLE & AUDITABLE — no complex logic, no vesting, no whitelist.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GXTokenSale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── State ────────────────────────────────────────────────────────

    /// @notice GX token being sold
    IERC20 public immutable gxToken;

    /// @notice USDC token (6 decimals on Arbitrum)
    IERC20 public immutable usdc;

    /// @notice USDT token (6 decimals on Arbitrum)
    IERC20 public immutable usdt;

    /// @notice Price per GX in USD cents (e.g., 8 = $0.08)
    /// GX has 18 decimals, USDC/USDT have 6 decimals
    /// For $0.08: user sends 80_000 USDC (6 dec) per 1_000_000 GX (18 dec)
    /// Formula: gxAmount = usdAmount * 10^18 / (priceInCents * 10^4)
    uint256 public immutable priceInCents;

    /// @notice Whether the sale is active
    bool public saleActive;

    /// @notice Total USDC raised
    uint256 public totalUsdcRaised;

    /// @notice Total USDT raised
    uint256 public totalUsdtRaised;

    /// @notice Total GX sold
    uint256 public totalGxSold;

    // ── Events ───────────────────────────────────────────────────────

    event TokensPurchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 gxAmount
    );
    event SaleToggled(bool active);
    event FundsWithdrawn(address indexed token, uint256 amount, address indexed to);
    event GxRecovered(uint256 amount, address indexed to);

    // ── Errors ───────────────────────────────────────────────────────

    error SaleNotActive();
    error ZeroAmount();
    error InvalidPaymentToken();
    error InsufficientGxBalance();

    // ── Constructor ──────────────────────────────────────────────────

    /**
     * @param _gxToken   GX ERC-20 token address
     * @param _usdc      USDC address on Arbitrum (0xaf88d065e77c8cC2239327C5EDb3A432268e5831)
     * @param _usdt      USDT address on Arbitrum (0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9)
     * @param _priceInCents  Price per GX in cents (8 = $0.08)
     */
    constructor(
        address _gxToken,
        address _usdc,
        address _usdt,
        uint256 _priceInCents
    ) Ownable(msg.sender) {
        require(_gxToken != address(0), "Zero GX address");
        require(_usdc != address(0), "Zero USDC address");
        require(_usdt != address(0), "Zero USDT address");
        require(_priceInCents > 0, "Zero price");

        gxToken = IERC20(_gxToken);
        usdc = IERC20(_usdc);
        usdt = IERC20(_usdt);
        priceInCents = _priceInCents;
        saleActive = true;
    }

    // ── Buy Functions ────────────────────────────────────────────────

    /**
     * @notice Buy GX tokens with USDC
     * @param usdcAmount Amount of USDC to spend (6 decimals)
     */
    function buyWithUSDC(uint256 usdcAmount) external nonReentrant {
        if (!saleActive) revert SaleNotActive();
        if (usdcAmount == 0) revert ZeroAmount();

        uint256 gxAmount = _calculateGxAmount(usdcAmount);
        if (gxToken.balanceOf(address(this)) < gxAmount) revert InsufficientGxBalance();

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        gxToken.safeTransfer(msg.sender, gxAmount);

        totalUsdcRaised += usdcAmount;
        totalGxSold += gxAmount;

        emit TokensPurchased(msg.sender, address(usdc), usdcAmount, gxAmount);
    }

    /**
     * @notice Buy GX tokens with USDT
     * @param usdtAmount Amount of USDT to spend (6 decimals)
     */
    function buyWithUSDT(uint256 usdtAmount) external nonReentrant {
        if (!saleActive) revert SaleNotActive();
        if (usdtAmount == 0) revert ZeroAmount();

        uint256 gxAmount = _calculateGxAmount(usdtAmount);
        if (gxToken.balanceOf(address(this)) < gxAmount) revert InsufficientGxBalance();

        usdt.safeTransferFrom(msg.sender, address(this), usdtAmount);
        gxToken.safeTransfer(msg.sender, gxAmount);

        totalUsdtRaised += usdtAmount;
        totalGxSold += gxAmount;

        emit TokensPurchased(msg.sender, address(usdt), usdtAmount, gxAmount);
    }

    // ── View Functions ───────────────────────────────────────────────

    /**
     * @notice Calculate how much GX you get for a given USD amount
     * @param usdAmount Amount in USDC/USDT (6 decimals)
     * @return gxAmount Amount of GX tokens (18 decimals)
     */
    function calculateGxAmount(uint256 usdAmount) external view returns (uint256) {
        return _calculateGxAmount(usdAmount);
    }

    /**
     * @notice GX tokens remaining in the sale
     */
    function gxRemaining() external view returns (uint256) {
        return gxToken.balanceOf(address(this));
    }

    /**
     * @notice Total USD raised (USDC + USDT combined, 6 decimals)
     */
    function totalRaised() external view returns (uint256) {
        return totalUsdcRaised + totalUsdtRaised;
    }

    // ── Owner Functions ──────────────────────────────────────────────

    /**
     * @notice Toggle the sale on/off
     */
    function toggleSale() external onlyOwner {
        saleActive = !saleActive;
        emit SaleToggled(saleActive);
    }

    /**
     * @notice Withdraw collected USDC to a wallet
     * @param to Destination wallet (Operations Treasury)
     */
    function withdrawUSDC(address to) external onlyOwner {
        uint256 balance = usdc.balanceOf(address(this));
        require(balance > 0, "No USDC to withdraw");
        usdc.safeTransfer(to, balance);
        emit FundsWithdrawn(address(usdc), balance, to);
    }

    /**
     * @notice Withdraw collected USDT to a wallet
     * @param to Destination wallet (Operations Treasury)
     */
    function withdrawUSDT(address to) external onlyOwner {
        uint256 balance = usdt.balanceOf(address(this));
        require(balance > 0, "No USDT to withdraw");
        usdt.safeTransfer(to, balance);
        emit FundsWithdrawn(address(usdt), balance, to);
    }

    /**
     * @notice Recover remaining unsold GX tokens (when sale ends)
     * @param to Destination wallet (deployer or exchange)
     */
    function recoverGx(address to) external onlyOwner {
        uint256 balance = gxToken.balanceOf(address(this));
        require(balance > 0, "No GX to recover");
        gxToken.safeTransfer(to, balance);
        emit GxRecovered(balance, to);
    }

    // ── Internal ─────────────────────────────────────────────────────

    /**
     * @dev Calculate GX amount from USD amount
     *      USDC/USDT = 6 decimals, GX = 18 decimals
     *      priceInCents = 8 means $0.08
     *      gxAmount = usdAmount * 10^18 / (priceInCents * 10^4)
     *      Example: 100 USDC (100_000_000 in 6 dec) → 1,250 GX (1250_000000000000000000 in 18 dec)
     */
    function _calculateGxAmount(uint256 usdAmount) private view returns (uint256) {
        // usdAmount is in 6 decimals
        // We need result in 18 decimals
        // price = priceInCents / 100 (in USD)
        // gxAmount = usdAmount / price * 10^(18-6)
        // = usdAmount * 100 * 10^12 / priceInCents
        return (usdAmount * 100 * 1e12) / priceInCents;
    }
}
