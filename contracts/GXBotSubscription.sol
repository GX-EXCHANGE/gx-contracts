// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  GXBotSubscription
 * @author GX Exchange
 * @notice Monthly subscription contract for GX trading bots.
 *
 *         Users pay GX tokens to subscribe to a tier.  50 % of payment is
 *         permanently burned, 50 % goes to the protocol treasury.
 *
 *         Tiers:
 *           0 — Free    (0 GX / month)
 *           1 — Starter (100 GX / month)
 *           2 — Pro     (500 GX / month)
 *           3 — Unlimited (2 000 GX / month)
 *
 * @dev    IMMUTABLE — no owner, no admin, no upgradability.
 *         - GX token and treasury address set at deploy.
 *         - Subscription lasts 30 days from payment.
 *         - Solidity 0.8.24, OpenZeppelin SafeERC20, ReentrancyGuard.
 */
contract GXBotSubscription is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Duration of one subscription period.
    uint256 public constant PERIOD = 30 days;

    /// @notice Burn share in basis points (50 %).
    uint256 public constant BURN_BPS = 5_000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Number of defined tiers (including Free).
    uint256 public constant TIER_COUNT = 4;

    // ═══════════════════════════════════════════════════════════════════════
    //  Enums
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Subscription tiers.
    enum Tier { Free, Starter, Pro, Unlimited }

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Per-user subscription record.
    struct Subscription {
        Tier tier;          // Current tier
        uint256 expiry;     // Unix timestamp when subscription expires
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice GX token (must implement ERC20Burnable).
    ERC20Burnable public immutable gxToken;

    /// @notice IERC20 interface for SafeERC20 operations on GX token.
    IERC20 public immutable gx;

    /// @notice Treasury address that receives 50 % of subscription payments.
    address public immutable treasury;

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Monthly price in GX (18 decimals) for each tier.
    ///         Populated once in constructor; effectively immutable.
    uint256[4] public tierPrices;

    /// @notice User -> subscription data.
    mapping(address => Subscription) public subscriptions;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error InvalidTier();
    error FreeTierNoPay();
    error AlreadySubscribed();
    error NotSubscribed();
    error SubscriptionStillActive();

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a user subscribes or upgrades.
    event Subscribed(address indexed user, Tier tier, uint256 expiry, uint256 gxPaid);

    /// @notice Emitted when a user renews their subscription.
    event Renewed(address indexed user, Tier tier, uint256 newExpiry, uint256 gxPaid);

    /// @notice Emitted when GX tokens are burned.
    event Burned(uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the bot subscription contract.
     * @param _gxToken   GX token address (must implement ERC20Burnable).
     * @param _treasury  Treasury address that receives 50 % of payments.
     */
    constructor(address _gxToken, address _treasury) {
        if (_gxToken == address(0) || _treasury == address(0)) revert ZeroAddress();

        gxToken = ERC20Burnable(_gxToken);
        gx = IERC20(_gxToken);
        treasury = _treasury;

        // Tier prices in GX (18 decimals).
        tierPrices[uint256(Tier.Free)]      = 0;
        tierPrices[uint256(Tier.Starter)]   = 100e18;
        tierPrices[uint256(Tier.Pro)]       = 500e18;
        tierPrices[uint256(Tier.Unlimited)] = 2_000e18;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check whether a user has an active subscription (any paid tier).
     * @param user Address to check.
     * @return active True if the subscription has not expired and tier > Free.
     */
    function isSubscribed(address user) external view returns (bool active) {
        Subscription memory s = subscriptions[user];
        active = s.tier != Tier.Free && block.timestamp <= s.expiry;
    }

    /**
     * @notice Return the user's current tier (Free if expired).
     * @param user Address to check.
     * @return tier Current effective tier.
     */
    function getTier(address user) external view returns (Tier tier) {
        Subscription memory s = subscriptions[user];
        if (s.tier == Tier.Free || block.timestamp > s.expiry) {
            return Tier.Free;
        }
        return s.tier;
    }

    /**
     * @notice Return full subscription details for a user.
     * @param user Address to check.
     */
    function getSubscription(address user) external view returns (Subscription memory) {
        return subscriptions[user];
    }

    /**
     * @notice Get the monthly price for a given tier.
     * @param tier Tier enum value.
     * @return price GX amount (18 decimals).
     */
    function getPrice(Tier tier) external view returns (uint256 price) {
        return tierPrices[uint256(tier)];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Subscribe
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Subscribe to a tier by paying GX tokens.
     * @dev    50 % of payment is burned, 50 % sent to treasury.
     *         The Free tier requires no payment.
     *         If user already has an active subscription on the same or higher
     *         tier, this reverts — use `renewSubscription()` instead.
     * @param tier The tier to subscribe to.
     */
    function subscribe(Tier tier) external nonReentrant {
        if (uint256(tier) >= TIER_COUNT) revert InvalidTier();

        Subscription storage s = subscriptions[msg.sender];

        // If user has an active paid subscription, must renew or wait for expiry.
        if (s.tier != Tier.Free && block.timestamp <= s.expiry) {
            revert AlreadySubscribed();
        }

        if (tier == Tier.Free) {
            s.tier = Tier.Free;
            s.expiry = 0;
            return;
        }

        uint256 price = tierPrices[uint256(tier)];
        _collectPayment(price);

        s.tier = tier;
        s.expiry = block.timestamp + PERIOD;

        emit Subscribed(msg.sender, tier, s.expiry, price);
    }

    /**
     * @notice Renew the current subscription for another 30 days.
     * @dev    Must have an existing paid subscription (active or recently expired).
     *         If still active, extends from current expiry.
     *         If expired, extends from now.
     */
    function renewSubscription() external nonReentrant {
        Subscription storage s = subscriptions[msg.sender];
        if (s.tier == Tier.Free) revert NotSubscribed();

        uint256 price = tierPrices[uint256(s.tier)];
        _collectPayment(price);

        // Extend from expiry if still active, otherwise from now.
        if (block.timestamp <= s.expiry) {
            s.expiry += PERIOD;
        } else {
            s.expiry = block.timestamp + PERIOD;
        }

        emit Renewed(msg.sender, s.tier, s.expiry, price);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev Pull GX from caller, burn 50 %, send 50 % to treasury.
     * @param amount Total GX to collect (18 decimals).
     */
    function _collectPayment(uint256 amount) internal {
        // Pull full amount from user.
        gx.safeTransferFrom(msg.sender, address(this), amount);

        uint256 burnAmount = (amount * BURN_BPS) / BPS;
        uint256 treasuryAmount = amount - burnAmount;

        // Burn 50 %.
        gxToken.burn(burnAmount);
        emit Burned(burnAmount);

        // Treasury 50 %.
        gx.safeTransfer(treasury, treasuryAmount);
    }
}
