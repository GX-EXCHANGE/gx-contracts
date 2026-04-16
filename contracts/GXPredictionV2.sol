// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  GXPredictionV2
 * @author GX Exchange
 * @notice Binary prediction market using ERC-1155 outcome tokens and a
 *         split/merge mechanism inspired by the Polymarket / Gnosis CTF model.
 *
 *         Core flow:
 *           1. Creator calls createMarket() with a 100 USDC deposit.
 *           2. Users call splitPosition() to deposit USDC and receive equal
 *              YES + NO ERC-1155 tokens (minus 1% fee).
 *           3. Users trade YES/NO tokens freely on any DEX or OTC.
 *           4. Users call mergePositions() to return equal YES + NO and get
 *              USDC back (no fee on merge).
 *           5. Oracle resolves the market; winners call redeemWinnings() to
 *              burn winning tokens for 1 USDC each.
 *           6. If INVALID: both YES and NO redeem at the split price.
 *
 * @dev    Token IDs: marketId * 2 = YES, marketId * 2 + 1 = NO.
 *         Solidity ^0.8.27, OpenZeppelin ERC1155 + SafeERC20 + ReentrancyGuard + Ownable.
 */
contract GXPredictionV2 is ERC1155, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //  Constants & Immutables
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Split fee in basis points (1%).
    uint256 public constant SPLIT_FEE_BPS = 100;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;

    /// @notice Grace period after resolution time before owner can emergency-resolve.
    uint256 public constant EMERGENCY_DELAY = 30 days;

    /// @notice USDC token used for all collateral.
    IERC20 public immutable usdc;

    /// @notice Address that receives all protocol fees.
    address public immutable feeRecipient;

    /// @notice USDC deposit required to create a market (anti-spam).
    uint256 public immutable creationDeposit;

    // ═══════════════════════════════════════════════════════════════════════
    //  Enums
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Possible resolution outcomes.
    enum Outcome { UNRESOLVED, YES, NO, INVALID }

    /// @notice Market lifecycle states.
    enum Status { Active, Resolved, Cancelled }

    // ═══════════════════════════════════════════════════════════════════════
    //  Structs
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Full state of a single prediction market.
    struct Market {
        string   question;        // Human-readable question
        address  creator;         // Address that created the market
        address  oracle;          // Address authorized to resolve
        uint256  resolutionTime;  // Earliest unix timestamp oracle can resolve
        Status   status;          // Current lifecycle state
        Outcome  outcome;         // Set upon resolution (YES / NO / INVALID)
        uint256  totalCollateral; // Total USDC collateral backing outcome tokens
        bool     depositRefunded; // Whether creation deposit was returned
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Auto-incrementing market ID counter.
    uint256 public nextMarketId;

    /// @notice Market ID -> Market data.
    mapping(uint256 => Market) public markets;

    // ═══════════════════════════════════════════════════════════════════════
    //  Errors
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error InvalidResolutionTime();
    error MarketNotActive();
    error MarketNotResolved();
    error NotOracle();
    error ResolutionTooEarly();
    error EmergencyTooEarly();
    error InvalidOutcome();
    error InsufficientBalance();
    error NothingToRedeem();
    error DepositAlreadyRefunded();

    // ═══════════════════════════════════════════════════════════════════════
    //  Events
    // ═══════════════════════════════════════════════════════════════════════

    event MarketCreated(
        uint256 indexed marketId,
        string  question,
        uint256 resolutionTime,
        address indexed oracle,
        address indexed creator
    );

    event PositionSplit(
        uint256 indexed marketId,
        address indexed user,
        uint256 amount,
        uint256 fee
    );

    event PositionsMerged(
        uint256 indexed marketId,
        address indexed user,
        uint256 amount
    );

    event MarketResolved(
        uint256 indexed marketId,
        Outcome outcome,
        bool    emergency
    );

    event WinningsRedeemed(
        uint256 indexed marketId,
        address indexed user,
        uint256 payout
    );

    event CreationDepositRefunded(
        uint256 indexed marketId,
        address indexed creator,
        uint256 amount
    );

    // ═══════════════════════════════════════════════════════════════════════
    //  Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @param _usdc            USDC token address on this chain.
     * @param _feeRecipient    Address that receives the 1% split fee.
     * @param _creationDeposit USDC amount required to create a market (e.g. 100e6).
     */
    constructor(
        address _usdc,
        address _feeRecipient,
        uint256 _creationDeposit
    )
        ERC1155("")
        Ownable(msg.sender)
    {
        if (_usdc == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        feeRecipient = _feeRecipient;
        creationDeposit = _creationDeposit;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Token ID Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the ERC-1155 token ID for the YES outcome of a market.
    function yesTokenId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2;
    }

    /// @notice Returns the ERC-1155 token ID for the NO outcome of a market.
    function noTokenId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2 + 1;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Views
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the full market struct for a given ID.
    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Market Creation
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new binary prediction market.
     * @dev    Requires a USDC deposit (anti-spam). The deposit is refunded to
     *         the creator when the market resolves normally (YES or NO).
     * @param question       Human-readable question.
     * @param resolutionTime Unix timestamp when the oracle may resolve.
     * @param oracle         Address authorized to call resolveMarket().
     * @return marketId      The ID of the newly created market.
     */
    function createMarket(
        string calldata question,
        uint256 resolutionTime,
        address oracle
    ) external nonReentrant returns (uint256 marketId) {
        if (oracle == address(0)) revert ZeroAddress();
        if (resolutionTime <= block.timestamp) revert InvalidResolutionTime();

        // Pull creation deposit from creator.
        if (creationDeposit > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), creationDeposit);
        }

        marketId = nextMarketId++;

        Market storage m = markets[marketId];
        m.question       = question;
        m.creator        = msg.sender;
        m.oracle         = oracle;
        m.resolutionTime = resolutionTime;
        m.status         = Status.Active;

        emit MarketCreated(marketId, question, resolutionTime, oracle, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Split / Merge  (Polymarket CTF-style)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Split USDC into equal YES + NO outcome tokens.
     * @dev    A 1% fee is taken on the USDC amount. The remaining USDC backs
     *         the newly minted tokens 1:1. Users receive both YES and NO tokens
     *         and can sell whichever side they disagree with on a DEX.
     * @param marketId The market to split into.
     * @param amount   USDC amount to deposit (before fee).
     */
    function splitPosition(
        uint256 marketId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Market storage m = markets[marketId];
        if (m.status != Status.Active) revert MarketNotActive();

        // Pull USDC from user.
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Deduct fee.
        uint256 fee = (amount * SPLIT_FEE_BPS) / BPS;
        uint256 net = amount - fee;

        // Send fee to recipient.
        if (fee > 0) {
            usdc.safeTransfer(feeRecipient, fee);
        }

        // Track collateral.
        m.totalCollateral += net;

        // Mint equal YES + NO tokens to the user.
        _mint(msg.sender, yesTokenId(marketId), net, "");
        _mint(msg.sender, noTokenId(marketId), net, "");

        emit PositionSplit(marketId, msg.sender, net, fee);
    }

    /**
     * @notice Merge equal amounts of YES + NO tokens back into USDC.
     * @dev    No fee is charged on merge (incentivizes closing positions).
     *         Burns the tokens and returns USDC 1:1.
     * @param marketId The market to merge from.
     * @param amount   Number of YES + NO token pairs to merge.
     */
    function mergePositions(
        uint256 marketId,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Market storage m = markets[marketId];
        if (m.status != Status.Active) revert MarketNotActive();

        // Verify user holds enough of both token types.
        uint256 yesId = yesTokenId(marketId);
        uint256 noId  = noTokenId(marketId);
        if (balanceOf(msg.sender, yesId) < amount) revert InsufficientBalance();
        if (balanceOf(msg.sender, noId)  < amount) revert InsufficientBalance();

        // Burn both tokens.
        _burn(msg.sender, yesId, amount);
        _burn(msg.sender, noId, amount);

        // Return USDC.
        m.totalCollateral -= amount;
        usdc.safeTransfer(msg.sender, amount);

        emit PositionsMerged(marketId, msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Resolution
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve a market. Only callable by the designated oracle.
     * @param marketId The market to resolve.
     * @param _outcome YES, NO, or INVALID.
     */
    function resolveMarket(
        uint256 marketId,
        Outcome _outcome
    ) external {
        Market storage m = markets[marketId];
        if (m.status != Status.Active) revert MarketNotActive();
        if (msg.sender != m.oracle) revert NotOracle();
        if (block.timestamp < m.resolutionTime) revert ResolutionTooEarly();
        if (_outcome == Outcome.UNRESOLVED) revert InvalidOutcome();

        m.status  = Status.Resolved;
        m.outcome = _outcome;

        // Refund creation deposit to creator on normal resolution (YES/NO).
        if (_outcome != Outcome.INVALID && creationDeposit > 0 && !m.depositRefunded) {
            m.depositRefunded = true;
            usdc.safeTransfer(m.creator, creationDeposit);
            emit CreationDepositRefunded(marketId, m.creator, creationDeposit);
        }

        emit MarketResolved(marketId, _outcome, false);
    }

    /**
     * @notice Emergency resolve — only callable by contract owner if oracle is
     *         unresponsive for 30+ days past the resolution time.
     * @param marketId The market to resolve.
     * @param _outcome YES, NO, or INVALID.
     */
    function emergencyResolve(
        uint256 marketId,
        Outcome _outcome
    ) external onlyOwner {
        Market storage m = markets[marketId];
        if (m.status != Status.Active) revert MarketNotActive();
        if (block.timestamp < m.resolutionTime + EMERGENCY_DELAY) revert EmergencyTooEarly();
        if (_outcome == Outcome.UNRESOLVED) revert InvalidOutcome();

        m.status  = Status.Resolved;
        m.outcome = _outcome;

        // Refund creation deposit on normal resolution.
        if (_outcome != Outcome.INVALID && creationDeposit > 0 && !m.depositRefunded) {
            m.depositRefunded = true;
            usdc.safeTransfer(m.creator, creationDeposit);
            emit CreationDepositRefunded(marketId, m.creator, creationDeposit);
        }

        emit MarketResolved(marketId, _outcome, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Redemption
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Redeem winning outcome tokens for USDC after market resolution.
     *
     *         - If YES won:     burn YES tokens, receive 1 USDC per token.
     *         - If NO won:      burn NO tokens, receive 1 USDC per token.
     *         - If INVALID:     burn either YES or NO tokens at 1 USDC per token
     *                           (both sides are redeemable at the split price).
     *
     * @param marketId The resolved market.
     */
    function redeemWinnings(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Resolved) revert MarketNotResolved();

        uint256 payout;

        if (m.outcome == Outcome.INVALID) {
            // Both YES and NO redeem at 1:1 (refund scenario).
            uint256 yesBalance = balanceOf(msg.sender, yesTokenId(marketId));
            uint256 noBalance  = balanceOf(msg.sender, noTokenId(marketId));
            uint256 total = yesBalance + noBalance;
            if (total == 0) revert NothingToRedeem();

            if (yesBalance > 0) _burn(msg.sender, yesTokenId(marketId), yesBalance);
            if (noBalance  > 0) _burn(msg.sender, noTokenId(marketId), noBalance);

            // Each token pair was backed by 1 USDC. In INVALID, each individual
            // token redeems at 0.5 USDC (since split minted 2 tokens per 1 USDC).
            // total tokens / 2 = USDC owed.
            payout = total / 2;
        } else {
            // Normal resolution: winning tokens redeem 1:1 for USDC.
            uint256 winId = m.outcome == Outcome.YES
                ? yesTokenId(marketId)
                : noTokenId(marketId);

            uint256 winBalance = balanceOf(msg.sender, winId);
            if (winBalance == 0) revert NothingToRedeem();

            _burn(msg.sender, winId, winBalance);
            payout = winBalance;
        }

        if (payout == 0) revert NothingToRedeem();

        m.totalCollateral -= payout;
        usdc.safeTransfer(msg.sender, payout);

        emit WinningsRedeemed(marketId, msg.sender, payout);
    }
}
