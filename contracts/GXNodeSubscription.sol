// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  GXNodeSubscription
 * @author GX Exchange
 * @notice USDC/USDT subscription contract for GX validator node plans.
 *
 *         Plans (monthly / yearly with 10% discount):
 *           0 — Starter    ($99  / $1,069)
 *           1 — Basic      ($199 / $2,149)
 *           2 — Pro        ($299 / $3,229)
 *           3 — Business   ($599 / $6,469)
 *           4 — Enterprise ($999 / $10,789)
 *
 *         Accepts USDC or USDT (both 6 decimals on Arbitrum).
 *
 * @dev    Solidity ^0.8.27, OpenZeppelin SafeERC20, ReentrancyGuard, Ownable.
 */
contract GXNodeSubscription is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    uint256 public constant MONTH = 30 days;
    uint256 public constant YEAR = 365 days;
    uint256 public constant PLAN_COUNT = 5;

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    struct Plan {
        string name;
        uint256 monthlyPrice; // 6 decimals (USDC/USDT)
        uint256 yearlyPrice;  // 6 decimals (12 months * 0.9)
    }

    struct Subscription {
        uint8 planId;
        bool yearly;
        address paymentToken; // which token was used (USDC or USDT)
        uint256 startTime;
        uint256 expiry;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutable / Storage
    // ═══════════════════════════════════════════════════════════════════════

    IERC20 public immutable usdc;
    IERC20 public immutable usdt;
    address public treasury;

    Plan[5] public plans;
    mapping(address => Subscription) public subscriptions;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error InvalidPlan();
    error InvalidToken();
    error NoActiveSubscription();

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event Subscribed(address indexed user, uint8 plan, bool yearly, address token, uint256 amount, uint256 expiry);
    event Renewed(address indexed user, address token, uint256 newExpiry);
    event FundsWithdrawn(address indexed token, address indexed to, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(address _usdc, address _usdt, address _treasury) Ownable(msg.sender) {
        if (_usdc == address(0) || _usdt == address(0) || _treasury == address(0)) revert ZeroAddress();

        usdc = IERC20(_usdc);
        usdt = IERC20(_usdt);
        treasury = _treasury;

        plans[0] = Plan("Starter",     99e6,  1069e6);
        plans[1] = Plan("Basic",      199e6,  2149e6);
        plans[2] = Plan("Pro",        299e6,  3229e6);
        plans[3] = Plan("Business",   599e6,  6469e6);
        plans[4] = Plan("Enterprise", 999e6, 10789e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal
    // ═══════════════════════════════════════════════════════════════════════

    function _resolveToken(address token) internal view returns (IERC20) {
        if (token == address(usdc)) return usdc;
        if (token == address(usdt)) return usdt;
        revert InvalidToken();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Check whether a user has an active node subscription.
    function isActive(address user) external view returns (bool) {
        return subscriptions[user].expiry > block.timestamp;
    }

    /// @notice Return full subscription details for a user.
    function getSubscription(address user)
        external
        view
        returns (uint8 planId, bool yearly, address paymentToken, uint256 startTime, uint256 expiry)
    {
        Subscription memory s = subscriptions[user];
        return (s.planId, s.yearly, s.paymentToken, s.startTime, s.expiry);
    }

    /// @notice Get pricing for a plan.
    function getPlan(uint8 planId)
        external
        view
        returns (string memory name, uint256 monthlyPrice, uint256 yearlyPrice)
    {
        if (planId >= PLAN_COUNT) revert InvalidPlan();
        Plan memory p = plans[planId];
        return (p.name, p.monthlyPrice, p.yearlyPrice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Subscribe
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Subscribe to a node plan by paying USDC or USDT.
     * @param planId  Plan index (0-4).
     * @param yearly  True for yearly billing (10% discount).
     * @param token   Address of payment token (must be USDC or USDT).
     */
    function subscribe(uint8 planId, bool yearly, address token) external nonReentrant {
        if (planId >= PLAN_COUNT) revert InvalidPlan();
        IERC20 payToken = _resolveToken(token);

        Plan memory p = plans[planId];
        uint256 amount = yearly ? p.yearlyPrice : p.monthlyPrice;
        uint256 duration = yearly ? YEAR : MONTH;

        payToken.safeTransferFrom(msg.sender, treasury, amount);

        Subscription storage s = subscriptions[msg.sender];
        s.planId = planId;
        s.yearly = yearly;
        s.paymentToken = token;
        s.startTime = block.timestamp;
        s.expiry = block.timestamp + duration;

        emit Subscribed(msg.sender, planId, yearly, token, amount, s.expiry);
    }

    /**
     * @notice Renew an existing subscription for another period.
     * @dev    If still active, extends from current expiry. If expired, extends from now.
     *         Uses the same payment token as the original subscription.
     */
    function renewSubscription() external nonReentrant {
        Subscription storage s = subscriptions[msg.sender];
        if (s.expiry == 0) revert NoActiveSubscription();

        IERC20 payToken = _resolveToken(s.paymentToken);
        Plan memory p = plans[s.planId];
        uint256 amount = s.yearly ? p.yearlyPrice : p.monthlyPrice;
        uint256 duration = s.yearly ? YEAR : MONTH;

        payToken.safeTransferFrom(msg.sender, treasury, amount);

        if (block.timestamp < s.expiry) {
            s.expiry += duration;
        } else {
            s.startTime = block.timestamp;
            s.expiry = block.timestamp + duration;
        }

        emit Renewed(msg.sender, s.paymentToken, s.expiry);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Owner
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw any ERC-20 held by this contract (safety valve).
     * @dev    In normal flow tokens go directly to treasury via safeTransferFrom.
     */
    function withdrawFunds(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No funds to withdraw");
        IERC20(token).safeTransfer(to, balance);
        emit FundsWithdrawn(token, to, balance);
    }

    /// @notice Update the treasury address.
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }
}
