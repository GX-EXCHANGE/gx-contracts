// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  GXPrediction
 * @author GX Exchange
 * @notice Binary prediction market inspired by the Gnosis Conditional Token
 *         Framework (CTF).  Users buy YES / NO outcome tokens with USDC;
 *         a designated oracle resolves the market; winners claim $1 per token.
 *
 * @dev    IMMUTABLE — no owner, no admin, no upgradability.
 *         - 2 % fee on every trade (hardcoded), sent to the fee distributor.
 *         - Markets auto-expire if not resolved within 30 days after
 *           resolution time (anyone can cancel and refund).
 *         - Outcome balances stored as mappings (not ERC-1155).
 *         - Solidity 0.8.24, OpenZeppelin SafeERC20, ReentrancyGuard.
 */
contract GXPrediction is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Fee in basis points taken on every buy / sell (2 %).
    uint256 public constant FEE_BPS = 200;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Grace period after resolution time before market can be cancelled.
    uint256 public constant EXPIRY_GRACE = 30 days;

    /// @notice Minimum USDC amount per trade.
    uint256 public constant MIN_TRADE = 1e6; // 1 USDC

    // ═══════════════════════════════════════════════════════════════════════
    //  Enums
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Possible outcomes for a binary market.
    enum Outcome { YES, NO }

    /// @notice Market lifecycle states.
    enum MarketStatus { Active, Resolved, Cancelled }

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Full state of a single prediction market.
    struct Market {
        string question;           // Human-readable question
        uint256 resolutionTime;    // Unix timestamp when oracle may resolve
        address oracle;            // Address authorized to resolve
        MarketStatus status;       // Current lifecycle state
        Outcome winningOutcome;    // Set upon resolution
        uint256 totalYes;          // Total YES tokens outstanding
        uint256 totalNo;           // Total NO tokens outstanding
        uint256 usdcPool;          // USDC collateral held for this market
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Immutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice USDC token used for all trading.
    IERC20 public immutable usdc;

    /// @notice Address that receives all protocol fees.
    address public immutable feeDistributor;

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Auto-incrementing market ID counter.
    uint256 public nextMarketId;

    /// @notice Market ID -> Market data.
    mapping(uint256 => Market) public markets;

    /// @notice Market ID -> Outcome -> user -> token balance.
    mapping(uint256 => mapping(Outcome => mapping(address => uint256))) public balances;

    /// @notice Market ID -> user -> whether winnings have been claimed.
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error BelowMinimumTrade();
    error InvalidResolutionTime();
    error MarketNotActive();
    error MarketNotResolved();
    error MarketAlreadyResolved();
    error NotOracle();
    error ResolutionTooEarly();
    error NotExpired();
    error InsufficientBalance();
    error AlreadyClaimed();
    error NothingToClaim();
    error InsufficientLiquidity();

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new prediction market is created.
    event MarketCreated(
        uint256 indexed marketId,
        string question,
        uint256 resolutionTime,
        address indexed oracle
    );

    /// @notice Emitted when a user buys outcome tokens.
    event OutcomeBought(
        uint256 indexed marketId,
        address indexed buyer,
        Outcome outcome,
        uint256 usdcSpent,
        uint256 tokensMinted
    );

    /// @notice Emitted when a user sells outcome tokens.
    event OutcomeSold(
        uint256 indexed marketId,
        address indexed seller,
        Outcome outcome,
        uint256 tokensBurned,
        uint256 usdcReturned
    );

    /// @notice Emitted when a market is resolved by its oracle.
    event MarketResolved(uint256 indexed marketId, Outcome winningOutcome);

    /// @notice Emitted when a winner claims their payout.
    event WinningsClaimed(uint256 indexed marketId, address indexed user, uint256 payout);

    /// @notice Emitted when an expired market is cancelled and refunds issued.
    event MarketCancelled(uint256 indexed marketId);

    /// @notice Emitted when a user receives a refund from a cancelled market.
    event Refunded(uint256 indexed marketId, address indexed user, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the prediction market contract.
     * @param _usdc            USDC token address.
     * @param _feeDistributor  Address that receives the 2 % trade fee.
     */
    constructor(address _usdc, address _feeDistributor) {
        if (_usdc == address(0) || _feeDistributor == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        feeDistributor = _feeDistributor;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the full market struct.
     * @param marketId Market ID.
     */
    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    /**
     * @notice Current implied price of an outcome token (18 decimals).
     * @dev    Price = thisOutcome / (totalYes + totalNo).
     *         Returns 0.5e18 if no tokens minted yet.
     * @param marketId Market ID.
     * @param outcome  YES or NO.
     */
    function getPrice(uint256 marketId, Outcome outcome) public view returns (uint256) {
        Market storage m = markets[marketId];
        uint256 total = m.totalYes + m.totalNo;
        if (total == 0) return 0.5e18;
        uint256 side = outcome == Outcome.YES ? m.totalYes : m.totalNo;
        return (side * 1e18) / total;
    }

    /**
     * @notice Check a user's outcome token balance.
     * @param marketId Market ID.
     * @param outcome  YES or NO.
     * @param user     Address to check.
     */
    function balanceOf(uint256 marketId, Outcome outcome, address user) external view returns (uint256) {
        return balances[marketId][outcome][user];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Market Lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new binary prediction market.
     * @param question        Human-readable question (e.g. "Will BTC hit 100k by Dec 2026?").
     * @param resolutionTime  Unix timestamp when the oracle may resolve the market.
     * @param oracle          Address authorized to resolve this market.
     * @return marketId       The ID of the newly created market.
     */
    function createMarket(
        string calldata question,
        uint256 resolutionTime,
        address oracle
    ) external returns (uint256 marketId) {
        if (oracle == address(0)) revert ZeroAddress();
        if (resolutionTime <= block.timestamp) revert InvalidResolutionTime();

        marketId = nextMarketId++;

        Market storage m = markets[marketId];
        m.question = question;
        m.resolutionTime = resolutionTime;
        m.oracle = oracle;
        m.status = MarketStatus.Active;

        emit MarketCreated(marketId, question, resolutionTime, oracle);
    }

    /**
     * @notice Buy outcome tokens with USDC.
     * @dev    The USDC is added to the market pool.  Outcome tokens are minted
     *         proportionally — the price is determined by the ratio of YES to
     *         total tokens (constant-sum bonding).
     *
     *         Price(YES) = totalYes / (totalYes + totalNo)
     *         tokens_minted = usdcAfterFee  (1 USDC = 1 outcome token at par)
     *
     *         The changing ratio after the purchase shifts the price for the
     *         next buyer, creating a natural market.
     *
     * @param marketId Market ID.
     * @param outcome  YES or NO.
     * @param amount   USDC amount to spend (USDC decimals).
     * @return tokens  Number of outcome tokens received.
     */
    function buyOutcome(
        uint256 marketId,
        Outcome outcome,
        uint256 amount
    ) external nonReentrant returns (uint256 tokens) {
        if (amount < MIN_TRADE) revert BelowMinimumTrade();
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Active) revert MarketNotActive();

        // Pull USDC.
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Deduct fee.
        uint256 fee = (amount * FEE_BPS) / BPS;
        uint256 net = amount - fee;

        // Send fee to distributor.
        if (fee > 0) {
            usdc.safeTransfer(feeDistributor, fee);
        }

        // Mint outcome tokens 1:1 with net USDC.
        tokens = net;
        balances[marketId][outcome][msg.sender] += tokens;

        if (outcome == Outcome.YES) {
            m.totalYes += tokens;
        } else {
            m.totalNo += tokens;
        }
        m.usdcPool += net;

        emit OutcomeBought(marketId, msg.sender, outcome, amount, tokens);
    }

    /**
     * @notice Sell outcome tokens back before resolution.
     * @dev    Returns USDC minus the 2 % fee.  The sell price is proportional
     *         to the user's share of total tokens on that side.
     * @param marketId Market ID.
     * @param outcome  YES or NO.
     * @param amount   Number of outcome tokens to sell.
     * @return usdcOut USDC returned after fee.
     */
    function sellOutcome(
        uint256 marketId,
        Outcome outcome,
        uint256 amount
    ) external nonReentrant returns (uint256 usdcOut) {
        if (amount == 0) revert ZeroAmount();
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Active) revert MarketNotActive();
        if (balances[marketId][outcome][msg.sender] < amount) revert InsufficientBalance();

        // Calculate USDC to return (proportional to pool).
        uint256 totalTokens = m.totalYes + m.totalNo;
        uint256 gross = (amount * m.usdcPool) / totalTokens;
        if (gross == 0) revert InsufficientLiquidity();

        // Deduct fee.
        uint256 fee = (gross * FEE_BPS) / BPS;
        usdcOut = gross - fee;

        // Update state.
        balances[marketId][outcome][msg.sender] -= amount;
        if (outcome == Outcome.YES) {
            m.totalYes -= amount;
        } else {
            m.totalNo -= amount;
        }
        m.usdcPool -= gross;

        // Transfer.
        if (fee > 0) {
            usdc.safeTransfer(feeDistributor, fee);
        }
        usdc.safeTransfer(msg.sender, usdcOut);

        emit OutcomeSold(marketId, msg.sender, outcome, amount, usdcOut);
    }

    /**
     * @notice Resolve a market — only callable by the designated oracle.
     * @param marketId       Market ID.
     * @param winningOutcome The winning side (YES or NO).
     */
    function resolveMarket(uint256 marketId, Outcome winningOutcome) external {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Active) revert MarketAlreadyResolved();
        if (msg.sender != m.oracle) revert NotOracle();
        if (block.timestamp < m.resolutionTime) revert ResolutionTooEarly();

        m.status = MarketStatus.Resolved;
        m.winningOutcome = winningOutcome;

        emit MarketResolved(marketId, winningOutcome);
    }

    /**
     * @notice Claim winnings from a resolved market.
     * @dev    Winners receive proportional share of the total USDC pool.
     *         Payout = (userWinningTokens / totalWinningTokens) * usdcPool.
     * @param marketId Market ID.
     * @return payout  USDC paid out.
     */
    function claimWinnings(uint256 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Resolved) revert MarketNotResolved();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();

        uint256 userTokens = balances[marketId][m.winningOutcome][msg.sender];
        if (userTokens == 0) revert NothingToClaim();

        uint256 totalWinning = m.winningOutcome == Outcome.YES ? m.totalYes : m.totalNo;

        // Payout = user's share of the entire pool.
        payout = (userTokens * m.usdcPool) / totalWinning;

        claimed[marketId][msg.sender] = true;

        usdc.safeTransfer(msg.sender, payout);

        emit WinningsClaimed(marketId, msg.sender, payout);
    }

    /**
     * @notice Cancel an expired market that was never resolved.
     * @dev    Callable by anyone if the resolution time + 30 days has passed
     *         without oracle resolution.  Sets status to Cancelled so users
     *         can claim refunds proportionally.
     * @param marketId Market ID.
     */
    function cancelExpiredMarket(uint256 marketId) external {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Active) revert MarketAlreadyResolved();
        if (block.timestamp < m.resolutionTime + EXPIRY_GRACE) revert NotExpired();

        m.status = MarketStatus.Cancelled;

        emit MarketCancelled(marketId);
    }

    /**
     * @notice Claim a refund from a cancelled market.
     * @dev    Refund is proportional: (userYes + userNo) / (totalYes + totalNo) * pool.
     * @param marketId Market ID.
     * @return refund  USDC refunded.
     */
    function claimRefund(uint256 marketId) external nonReentrant returns (uint256 refund) {
        Market storage m = markets[marketId];
        if (m.status != MarketStatus.Cancelled) revert MarketNotResolved();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();

        uint256 userYes = balances[marketId][Outcome.YES][msg.sender];
        uint256 userNo  = balances[marketId][Outcome.NO][msg.sender];
        uint256 userTotal = userYes + userNo;
        if (userTotal == 0) revert NothingToClaim();

        uint256 totalTokens = m.totalYes + m.totalNo;
        refund = (userTotal * m.usdcPool) / totalTokens;

        claimed[marketId][msg.sender] = true;

        usdc.safeTransfer(msg.sender, refund);

        emit Refunded(marketId, msg.sender, refund);
    }
}
