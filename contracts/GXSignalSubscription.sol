// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  GXSignalSubscription
 * @author GX Exchange
 * @notice Signal provider copy-trading subscription marketplace.
 *
 *         Anyone can register as a signal provider and set a monthly GX price.
 *         Users subscribe by paying GX: 90 % goes to the provider, 10 % is
 *         permanently burned.
 *
 * @dev    IMMUTABLE — no owner, no admin, no upgradability.
 *         - GX token set at deploy.
 *         - Subscription lasts 30 days from payment.
 *         - Provider can update price (only affects new subscriptions).
 *         - Solidity 0.8.24, OpenZeppelin SafeERC20, ReentrancyGuard.
 */
contract GXSignalSubscription is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Duration of one subscription period.
    uint256 public constant PERIOD = 30 days;

    /// @notice Burn share in basis points (10 %).
    uint256 public constant BURN_BPS = 1_000;

    /// @notice Provider share in basis points (90 %).
    uint256 public constant PROVIDER_BPS = 9_000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Minimum monthly price a provider can set (1 GX).
    uint256 public constant MIN_PRICE = 1e18;

    /// @notice Maximum monthly price a provider can set (100 000 GX).
    uint256 public constant MAX_PRICE = 100_000e18;

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Signal provider data.
    struct Provider {
        address wallet;         // Provider's address (receives payments)
        uint256 monthlyPriceGx; // Monthly subscription price in GX (18 decimals)
        uint256 subscriberCount;// Current active subscriber count
        bool active;            // Whether the provider is accepting new subs
    }

    /// @notice Per-subscriber record for a given provider.
    struct Sub {
        uint256 expiry; // Unix timestamp when subscription expires
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice GX token (must implement ERC20Burnable).
    ERC20Burnable public immutable gxToken;

    /// @notice IERC20 interface for SafeERC20 operations on GX token.
    IERC20 public immutable gx;

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Auto-incrementing provider ID counter.
    uint256 public nextProviderId;

    /// @notice Provider ID -> provider data.
    mapping(uint256 => Provider) public providers;

    /// @notice Wallet address -> provider ID (0 means not registered).
    ///         Provider IDs start at 1 to distinguish unregistered.
    mapping(address => uint256) public providerByWallet;

    /// @notice Provider ID -> subscriber address -> subscription record.
    mapping(uint256 => mapping(address => Sub)) public subs;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error PriceTooLow();
    error PriceTooHigh();
    error AlreadyRegistered();
    error ProviderNotFound();
    error ProviderNotActive();
    error AlreadySubscribed();
    error NotSubscribed();
    error CannotSubscribeToSelf();

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new signal provider registers.
    event ProviderRegistered(uint256 indexed providerId, address indexed wallet, uint256 monthlyPriceGx);

    /// @notice Emitted when a provider updates their price.
    event PriceUpdated(uint256 indexed providerId, uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when a provider deactivates.
    event ProviderDeactivated(uint256 indexed providerId);

    /// @notice Emitted when a provider reactivates.
    event ProviderReactivated(uint256 indexed providerId);

    /// @notice Emitted when a user subscribes to a provider.
    event Subscribed(
        uint256 indexed providerId,
        address indexed subscriber,
        uint256 expiry,
        uint256 gxPaid,
        uint256 providerShare,
        uint256 burned
    );

    /// @notice Emitted when a user unsubscribes.
    event Unsubscribed(uint256 indexed providerId, address indexed subscriber);

    /// @notice Emitted when GX tokens are burned.
    event Burned(uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the signal subscription contract.
     * @param _gxToken GX token address (must implement ERC20Burnable).
     */
    constructor(address _gxToken) {
        if (_gxToken == address(0)) revert ZeroAddress();
        gxToken = ERC20Burnable(_gxToken);
        gx = IERC20(_gxToken);
        // Provider IDs start at 1 (0 is sentinel for "not registered").
        nextProviderId = 1;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get full provider data.
     * @param providerId Provider ID.
     */
    function getProvider(uint256 providerId) external view returns (Provider memory) {
        return providers[providerId];
    }

    /**
     * @notice Check if a user is currently subscribed to a provider.
     * @param user       Subscriber address.
     * @param providerId Provider ID.
     * @return active    True if subscription has not expired.
     */
    function isSubscribed(address user, uint256 providerId) external view returns (bool active) {
        return block.timestamp <= subs[providerId][user].expiry;
    }

    /**
     * @notice Get active subscriber count for a provider.
     * @param providerId Provider ID.
     * @return count     Number of subscribers (note: may include recently expired).
     */
    function getProviderSubscribers(uint256 providerId) external view returns (uint256 count) {
        return providers[providerId].subscriberCount;
    }

    /**
     * @notice Get subscription details for a user-provider pair.
     * @param providerId Provider ID.
     * @param user       Subscriber address.
     */
    function getSubscription(uint256 providerId, address user) external view returns (Sub memory) {
        return subs[providerId][user];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Provider Management
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register as a signal provider.
     * @param monthlyPriceGx Monthly subscription price in GX (18 decimals).
     * @return providerId    The assigned provider ID.
     */
    function registerProvider(uint256 monthlyPriceGx) external returns (uint256 providerId) {
        if (providerByWallet[msg.sender] != 0) revert AlreadyRegistered();
        if (monthlyPriceGx < MIN_PRICE) revert PriceTooLow();
        if (monthlyPriceGx > MAX_PRICE) revert PriceTooHigh();

        providerId = nextProviderId++;

        providers[providerId] = Provider({
            wallet: msg.sender,
            monthlyPriceGx: monthlyPriceGx,
            subscriberCount: 0,
            active: true
        });

        providerByWallet[msg.sender] = providerId;

        emit ProviderRegistered(providerId, msg.sender, monthlyPriceGx);
    }

    /**
     * @notice Update monthly price (only affects new subscriptions).
     * @dev    Only callable by the provider's registered wallet.
     * @param newPriceGx New monthly price in GX (18 decimals).
     */
    function updatePrice(uint256 newPriceGx) external {
        uint256 pid = providerByWallet[msg.sender];
        if (pid == 0) revert ProviderNotFound();
        if (newPriceGx < MIN_PRICE) revert PriceTooLow();
        if (newPriceGx > MAX_PRICE) revert PriceTooHigh();

        uint256 oldPrice = providers[pid].monthlyPriceGx;
        providers[pid].monthlyPriceGx = newPriceGx;

        emit PriceUpdated(pid, oldPrice, newPriceGx);
    }

    /**
     * @notice Deactivate provider (stop accepting new subscribers).
     * @dev    Existing subscriptions remain valid until expiry.
     */
    function deactivateProvider() external {
        uint256 pid = providerByWallet[msg.sender];
        if (pid == 0) revert ProviderNotFound();
        providers[pid].active = false;
        emit ProviderDeactivated(pid);
    }

    /**
     * @notice Reactivate provider.
     */
    function reactivateProvider() external {
        uint256 pid = providerByWallet[msg.sender];
        if (pid == 0) revert ProviderNotFound();
        providers[pid].active = true;
        emit ProviderReactivated(pid);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Subscribe / Unsubscribe
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Subscribe to a signal provider by paying GX.
     * @dev    90 % of payment goes to the provider, 10 % is burned.
     *         If the user already has an active subscription to this provider,
     *         this reverts — use renewSubscription() instead.
     * @param providerId Provider ID.
     */
    function subscribe(uint256 providerId) external nonReentrant {
        Provider storage p = providers[providerId];
        if (p.wallet == address(0)) revert ProviderNotFound();
        if (!p.active) revert ProviderNotActive();
        if (p.wallet == msg.sender) revert CannotSubscribeToSelf();

        Sub storage s = subs[providerId][msg.sender];
        if (block.timestamp <= s.expiry) revert AlreadySubscribed();

        uint256 price = p.monthlyPriceGx;
        _collectPayment(price, p.wallet);

        s.expiry = block.timestamp + PERIOD;
        p.subscriberCount += 1;

        emit Subscribed(
            providerId,
            msg.sender,
            s.expiry,
            price,
            (price * PROVIDER_BPS) / BPS,
            (price * BURN_BPS) / BPS
        );
    }

    /**
     * @notice Renew an existing subscription for another 30 days.
     * @param providerId Provider ID.
     */
    function renewSubscription(uint256 providerId) external nonReentrant {
        Provider storage p = providers[providerId];
        if (p.wallet == address(0)) revert ProviderNotFound();

        Sub storage s = subs[providerId][msg.sender];
        // Must have a prior subscription (even if expired).
        if (s.expiry == 0) revert NotSubscribed();

        uint256 price = p.monthlyPriceGx;
        _collectPayment(price, p.wallet);

        // Extend from expiry if still active, otherwise from now.
        if (block.timestamp <= s.expiry) {
            s.expiry += PERIOD;
        } else {
            s.expiry = block.timestamp + PERIOD;
            // Re-increment subscriber count if they had lapsed.
            p.subscriberCount += 1;
        }

        emit Subscribed(
            providerId,
            msg.sender,
            s.expiry,
            price,
            (price * PROVIDER_BPS) / BPS,
            (price * BURN_BPS) / BPS
        );
    }

    /**
     * @notice Unsubscribe from a provider (no refund for current period).
     * @param providerId Provider ID.
     */
    function unsubscribe(uint256 providerId) external {
        Sub storage s = subs[providerId][msg.sender];
        if (s.expiry == 0 || block.timestamp > s.expiry) revert NotSubscribed();

        // Expire immediately — no refund.
        s.expiry = block.timestamp;
        providers[providerId].subscriberCount -= 1;

        emit Unsubscribed(providerId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev Pull GX from caller, send 90 % to provider, burn 10 %.
     * @param amount   Total GX to collect (18 decimals).
     * @param provider Provider wallet address.
     */
    function _collectPayment(uint256 amount, address provider) internal {
        // Pull full amount from subscriber.
        gx.safeTransferFrom(msg.sender, address(this), amount);

        uint256 burnAmount = (amount * BURN_BPS) / BPS;
        uint256 providerAmount = amount - burnAmount;

        // Burn 10 %.
        gxToken.burn(burnAmount);
        emit Burned(burnAmount);

        // Provider 90 %.
        gx.safeTransfer(provider, providerAmount);
    }
}
