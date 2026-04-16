// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title GXInsurance
 * @author GX Exchange — inspired by Liquity StabilityPool pattern
 * @notice Insurance fund that absorbs protocol shortfalls. Receives 20% of all
 *         protocol fees via GXFeeDistributor and holds USDC as reserve.
 *
 *         Registered protocol contracts (GXBridge, GXUSD, GXLending) can draw
 *         from this fund to cover shortfalls (bad debt, bridge losses, etc.).
 *
 *         Anyone can deposit additional USDC to grow the fund. If the fund
 *         balance exceeds the maximum cap ($50M by default), excess is
 *         automatically forwarded to the treasury.
 *
 * @dev IMMUTABLE — no proxy, no admin, no owner, no upgrades.
 *      Registered callers and all parameters are locked at deployment.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ──────────────────────────────────────────────────────────────────────────────
// Custom errors
// ──────────────────────────────────────────────────────────────────────────────

error ZeroAmount();
error ZeroAddress();
error CallerNotRegistered();
error InsufficientFundBalance();

/**
 * @notice GXInsurance — immutable protocol insurance fund.
 */
contract GXInsurance is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ======================================================================
       IMMUTABLE STATE (set once in constructor)
       ====================================================================== */

    /// @notice The reserve token (USDC).
    IERC20 public immutable usdc;

    /// @notice Maximum fund balance (in USDC units). Excess sent to treasury.
    uint256 public immutable maxFundSize;

    /// @notice Treasury address — receives excess funds above the cap.
    address public immutable treasury;

    /// @notice GXBridge contract — authorised to call coverShortfall.
    address public immutable gxBridge;

    /// @notice GXUSD (GXStablecoin) contract — authorised to call coverShortfall.
    address public immutable gxUSD;

    /// @notice GXLending contract — authorised to call coverShortfall.
    address public immutable gxLending;

    /* ======================================================================
       EVENTS
       ====================================================================== */

    /// @notice Emitted when anyone deposits USDC into the fund.
    event Deposited(address indexed depositor, uint256 amount);

    /// @notice Emitted when a registered contract draws from the fund.
    event ShortfallCovered(
        address indexed caller,
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when excess funds are forwarded to the treasury.
    event ExcessForwarded(uint256 amount);

    /* ======================================================================
       CONSTRUCTOR
       ====================================================================== */

    /**
     * @param _usdc        Address of the USDC token.
     * @param _maxFundSize Maximum fund balance in USDC units (e.g. 50_000_000e6 for $50M).
     * @param _treasury    Treasury address to receive excess funds.
     * @param _gxBridge    GXBridge contract address (authorised caller).
     * @param _gxUSD       GXUSD / GXStablecoin contract address (authorised caller).
     * @param _gxLending   GXLending contract address (authorised caller).
     */
    constructor(
        address _usdc,
        uint256 _maxFundSize,
        address _treasury,
        address _gxBridge,
        address _gxUSD,
        address _gxLending
    ) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_gxBridge == address(0)) revert ZeroAddress();
        if (_gxUSD == address(0)) revert ZeroAddress();
        if (_gxLending == address(0)) revert ZeroAddress();
        if (_maxFundSize == 0) revert ZeroAmount();

        usdc = IERC20(_usdc);
        maxFundSize = _maxFundSize;
        treasury = _treasury;
        gxBridge = _gxBridge;
        gxUSD = _gxUSD;
        gxLending = _gxLending;
    }

    /* ======================================================================
       CORE — Deposit
       ====================================================================== */

    /**
     * @notice Deposit USDC into the insurance fund. Anyone can call this —
     *         the GXFeeDistributor sends 20% of protocol fees here, and
     *         additional contributors can top up directly.
     *
     *         If the deposit pushes the balance above maxFundSize, the excess
     *         is automatically forwarded to the treasury.
     *
     * @param _amount Amount of USDC to deposit (6 decimals).
     */
    function depositToFund(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();

        // Pull USDC from caller.
        usdc.safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposited(msg.sender, _amount);

        // Check if fund exceeds cap and forward excess.
        _forwardExcess();
    }

    /* ======================================================================
       CORE — Cover Shortfall
       ====================================================================== */

    /**
     * @notice Draw USDC from the fund to cover a protocol shortfall.
     *         Only callable by the three registered protocol contracts
     *         (GXBridge, GXUSD, GXLending) — set immutably at deploy.
     *
     * @param _amount    Amount of USDC to draw.
     * @param _recipient Address to receive the USDC.
     */
    function coverShortfall(uint256 _amount, address _recipient) external nonReentrant {
        if (_amount == 0) revert ZeroAmount();
        if (_recipient == address(0)) revert ZeroAddress();

        // Only registered callers.
        if (
            msg.sender != gxBridge &&
            msg.sender != gxUSD &&
            msg.sender != gxLending
        ) {
            revert CallerNotRegistered();
        }

        uint256 balance = usdc.balanceOf(address(this));
        if (_amount > balance) revert InsufficientFundBalance();

        usdc.safeTransfer(_recipient, _amount);

        emit ShortfallCovered(msg.sender, _recipient, _amount);
    }

    /* ======================================================================
       VIEW FUNCTIONS
       ====================================================================== */

    /**
     * @notice Current USDC balance held by the insurance fund.
     * @return The balance in USDC units (6 decimals).
     */
    function getBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Check whether an address is a registered caller.
     * @param _addr Address to check.
     * @return True if the address is GXBridge, GXUSD, or GXLending.
     */
    function isRegisteredCaller(address _addr) external view returns (bool) {
        return _addr == gxBridge || _addr == gxUSD || _addr == gxLending;
    }

    /* ======================================================================
       INTERNAL
       ====================================================================== */

    /**
     * @dev If the current balance exceeds maxFundSize, forward the excess
     *      to the treasury.
     */
    function _forwardExcess() internal {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > maxFundSize) {
            uint256 excess = balance - maxFundSize;
            usdc.safeTransfer(treasury, excess);
            emit ExcessForwarded(excess);
        }
    }
}
