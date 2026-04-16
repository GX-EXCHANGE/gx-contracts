// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title  GXPredictionV3
 * @author GX Exchange
 * @notice Binary prediction market using ERC-1155 outcome tokens with an
 *         operator-settled order book model inspired by Polymarket / Gnosis CTF.
 *
 *         Core flows:
 *           1. Operator creates markets with a designated oracle.
 *           2. Users split USDC into equal YES + NO tokens (fee on split).
 *           3. Engine (operator) settles off-chain order-book trades on-chain.
 *           4. Oracle resolves; winners redeem tokens for USDC.
 *
 * @dev    Token IDs: marketId * 2 = YES, marketId * 2 + 1 = NO.
 *         Uses uint128 for amounts to pack storage efficiently.
 */
contract GXPredictionV3 is ERC1155, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    //  Enums
    // -----------------------------------------------------------------------

    enum Outcome  { UNRESOLVED, YES, NO, INVALID }
    enum Status   { Active, Halted, Resolved, Cancelled }

    // -----------------------------------------------------------------------
    //  Data Structures
    // -----------------------------------------------------------------------

    struct Market {
        string   question;
        bytes32  questionId;
        address  creator;
        address  oracle;
        uint64   resolutionTime;
        uint64   createdAt;
        Status   status;
        Outcome  outcome;
        uint128  totalCollateral;
        uint128  totalYesSupply;
        uint128  totalNoSupply;
    }

    /// @notice Batch settlement instruction used by the operator engine.
    struct Settlement {
        uint256  marketId;
        address  user;
        bool     isBuy;        // true = BUY, false = SELL
        bool     isYes;        // true = YES token, false = NO token
        uint128  tokenAmount;
        uint128  usdcAmount;
    }

    // -----------------------------------------------------------------------
    //  State
    // -----------------------------------------------------------------------

    IERC20  public immutable usdc;
    address public operator;
    address public feeRecipient;
    uint16  public feeBps;              // max 500 (5 %)

    uint256 private _marketCount;
    mapping(uint256 => Market) private _markets;

    /// @dev Tracks whether a user has already redeemed for a given market.
    mapping(uint256 => mapping(address => bool)) private _redeemed;

    uint16  private constant MAX_FEE_BPS = 500;
    uint64  private constant EMERGENCY_DELAY = 30 days;

    // -----------------------------------------------------------------------
    //  Events
    // -----------------------------------------------------------------------

    event MarketCreated(uint256 indexed marketId, string question, address oracle, uint64 resolutionTime);
    event PositionSplit(uint256 indexed marketId, address indexed user, uint128 amount);
    event PositionMerged(uint256 indexed marketId, address indexed user, uint128 amount);
    event TradeSettled(uint256 indexed marketId, address indexed user, bool isBuy, bool isYes, uint128 tokenAmount, uint128 usdcAmount);
    event MarketResolved(uint256 indexed marketId, Outcome outcome);
    event WinningsRedeemed(uint256 indexed marketId, address indexed user, uint128 amount);
    event MarketHalted(uint256 indexed marketId);
    event MarketUnhalted(uint256 indexed marketId);

    // -----------------------------------------------------------------------
    //  Errors
    // -----------------------------------------------------------------------

    error NotOperator();
    error NotOracle();
    error MarketNotActive(uint256 marketId);
    error MarketNotResolved(uint256 marketId);
    error ZeroAmount();
    error ZeroAddress();
    error FeeTooHigh();
    error ResolutionTooEarly();
    error EmergencyTooEarly();
    error InvalidOutcome();
    error AlreadyRedeemed();
    error NothingToRedeem();
    error MarketDoesNotExist(uint256 marketId);

    // -----------------------------------------------------------------------
    //  Modifiers
    // -----------------------------------------------------------------------

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyActiveMarket(uint256 marketId) {
        if (marketId >= _marketCount) revert MarketDoesNotExist(marketId);
        if (_markets[marketId].status != Status.Active) revert MarketNotActive(marketId);
        _;
    }

    // -----------------------------------------------------------------------
    //  Constructor
    // -----------------------------------------------------------------------

    constructor(
        address _usdc,
        address _feeRecipient,
        address _operator,
        uint16  _feeBps
    )
        ERC1155("")
        Ownable(msg.sender)
    {
        if (_usdc == address(0) || _feeRecipient == address(0) || _operator == address(0))
            revert ZeroAddress();
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        usdc         = IERC20(_usdc);
        feeRecipient = _feeRecipient;
        operator     = _operator;
        feeBps       = _feeBps;
    }

    // -----------------------------------------------------------------------
    //  Admin (onlyOwner)
    // -----------------------------------------------------------------------

    /// @notice Replace the operator (engine hot-wallet).
    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert ZeroAddress();
        operator = _operator;
    }

    /// @notice Update the protocol fee rate (max 500 bps = 5 %).
    function setFeeRate(uint16 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = _feeBps;
    }

    /// @notice Update the fee recipient address.
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
    }

    /// @notice Halt a market — blocks splits, merges, and settlements.
    function haltMarket(uint256 marketId) external onlyOwner {
        if (marketId >= _marketCount) revert MarketDoesNotExist(marketId);
        _markets[marketId].status = Status.Halted;
        emit MarketHalted(marketId);
    }

    /// @notice Re-activate a halted market.
    function unhaltMarket(uint256 marketId) external onlyOwner {
        if (marketId >= _marketCount) revert MarketDoesNotExist(marketId);
        require(_markets[marketId].status == Status.Halted, "Not halted");
        _markets[marketId].status = Status.Active;
        emit MarketUnhalted(marketId);
    }

    // -----------------------------------------------------------------------
    //  Market Creation (operator or owner)
    // -----------------------------------------------------------------------

    /// @notice Create a new binary prediction market.
    /// @return marketId The sequential ID of the newly created market.
    function createMarket(
        string calldata question,
        bytes32 questionId,
        uint64  resolutionTime,
        address oracle
    ) external returns (uint256 marketId) {
        require(msg.sender == operator || msg.sender == owner(), "Not authorized");
        if (oracle == address(0)) revert ZeroAddress();
        require(resolutionTime > block.timestamp, "Resolution must be in the future");

        marketId = _marketCount++;

        Market storage m = _markets[marketId];
        m.question       = question;
        m.questionId     = questionId;
        m.creator        = msg.sender;
        m.oracle         = oracle;
        m.resolutionTime = resolutionTime;
        m.createdAt      = uint64(block.timestamp);
        m.status         = Status.Active;
        // outcome defaults to UNRESOLVED, supplies default to 0

        emit MarketCreated(marketId, question, oracle, resolutionTime);
    }

    // -----------------------------------------------------------------------
    //  User Self-Service: Split & Merge
    // -----------------------------------------------------------------------

    /// @notice Deposit USDC and receive equal YES + NO tokens (fee deducted).
    function splitPosition(uint256 marketId, uint128 amount)
        external
        nonReentrant
        onlyActiveMarket(marketId)
    {
        if (amount == 0) revert ZeroAmount();

        // Pull full USDC amount from user
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate and transfer fee
        uint128 fee = (amount * feeBps) / 10_000;
        uint128 net = amount - fee;
        if (fee > 0) {
            usdc.safeTransfer(feeRecipient, fee);
        }

        // Mint equal YES + NO tokens for the net amount
        Market storage m = _markets[marketId];
        m.totalCollateral += net;
        m.totalYesSupply  += net;
        m.totalNoSupply   += net;

        _mint(msg.sender, yesTokenId(marketId), net, "");
        _mint(msg.sender, noTokenId(marketId),  net, "");

        emit PositionSplit(marketId, msg.sender, net);
    }

    /// @notice Burn equal YES + NO tokens to recover USDC (no fee).
    function mergePositions(uint256 marketId, uint128 amount)
        external
        nonReentrant
        onlyActiveMarket(marketId)
    {
        if (amount == 0) revert ZeroAmount();

        // Burn YES + NO from user (requires isApprovedForAll or self)
        _burn(msg.sender, yesTokenId(marketId), amount);
        _burn(msg.sender, noTokenId(marketId),  amount);

        Market storage m = _markets[marketId];
        m.totalCollateral -= amount;
        m.totalYesSupply  -= amount;
        m.totalNoSupply   -= amount;

        // Return USDC
        usdc.safeTransfer(msg.sender, amount);

        emit PositionMerged(marketId, msg.sender, amount);
    }

    // -----------------------------------------------------------------------
    //  Engine Settlement (onlyOperator)
    // -----------------------------------------------------------------------

    /// @notice Batch-settle order-book trades. For BUY: pull USDC, mint tokens.
    ///         For SELL: burn tokens, send USDC.
    function settleTrades(Settlement[] calldata settlements) external onlyOperator nonReentrant {
        uint256 len = settlements.length;
        for (uint256 i; i < len; ++i) {
            Settlement calldata s = settlements[i];
            if (s.tokenAmount == 0) revert ZeroAmount();

            uint256 mId = s.marketId;
            if (mId >= _marketCount) revert MarketDoesNotExist(mId);
            if (_markets[mId].status != Status.Active) revert MarketNotActive(mId);

            uint256 tokId = s.isYes ? yesTokenId(mId) : noTokenId(mId);

            if (s.isBuy) {
                // Pull USDC from buyer, mint outcome tokens
                usdc.safeTransferFrom(s.user, address(this), s.usdcAmount);
                _markets[mId].totalCollateral += s.usdcAmount;

                if (s.isYes) {
                    _markets[mId].totalYesSupply += s.tokenAmount;
                } else {
                    _markets[mId].totalNoSupply += s.tokenAmount;
                }

                _mint(s.user, tokId, s.tokenAmount, "");
            } else {
                // Burn outcome tokens, send USDC to seller
                _burn(s.user, tokId, s.tokenAmount);

                if (s.isYes) {
                    _markets[mId].totalYesSupply -= s.tokenAmount;
                } else {
                    _markets[mId].totalNoSupply -= s.tokenAmount;
                }

                _markets[mId].totalCollateral -= s.usdcAmount;
                usdc.safeTransfer(s.user, s.usdcAmount);
            }

            emit TradeSettled(mId, s.user, s.isBuy, s.isYes, s.tokenAmount, s.usdcAmount);
        }
    }

    /// @notice Settle a matched trade where both sides deposit USDC and each
    ///         receives their chosen outcome token. Net effect: full split.
    function settleWithMint(
        uint256 marketId,
        address buyer,
        address seller,
        bool    buyerWantsYes,
        uint128 amount
    ) external onlyOperator nonReentrant onlyActiveMarket(marketId) {
        if (amount == 0) revert ZeroAmount();

        // Both parties deposit USDC
        usdc.safeTransferFrom(buyer,  address(this), amount);
        usdc.safeTransferFrom(seller, address(this), amount);

        Market storage m = _markets[marketId];
        m.totalCollateral += amount * 2;
        m.totalYesSupply  += amount;
        m.totalNoSupply   += amount;

        if (buyerWantsYes) {
            _mint(buyer,  yesTokenId(marketId), amount, "");
            _mint(seller, noTokenId(marketId),  amount, "");
        } else {
            _mint(buyer,  noTokenId(marketId),  amount, "");
            _mint(seller, yesTokenId(marketId), amount, "");
        }

        emit TradeSettled(marketId, buyer,  true,  buyerWantsYes,  amount, amount);
        emit TradeSettled(marketId, seller, true,  !buyerWantsYes, amount, amount);
    }

    /// @notice Settle a matched trade where a YES holder and NO holder both
    ///         surrender tokens and each receives USDC. Net effect: full merge.
    function settleWithMerge(
        uint256 marketId,
        address yesHolder,
        address noHolder,
        uint128 amount
    ) external onlyOperator nonReentrant onlyActiveMarket(marketId) {
        if (amount == 0) revert ZeroAmount();

        // Burn tokens from both holders
        _burn(yesHolder, yesTokenId(marketId), amount);
        _burn(noHolder,  noTokenId(marketId),  amount);

        Market storage m = _markets[marketId];
        m.totalCollateral -= amount * 2;
        m.totalYesSupply  -= amount;
        m.totalNoSupply   -= amount;

        // Return USDC to both
        usdc.safeTransfer(yesHolder, amount);
        usdc.safeTransfer(noHolder,  amount);

        emit TradeSettled(marketId, yesHolder, false, true,  amount, amount);
        emit TradeSettled(marketId, noHolder,  false, false, amount, amount);
    }

    // -----------------------------------------------------------------------
    //  Resolution
    // -----------------------------------------------------------------------

    /// @notice Oracle resolves the market after the resolution time has passed.
    function resolveMarket(uint256 marketId, Outcome _outcome) external {
        if (marketId >= _marketCount) revert MarketDoesNotExist(marketId);
        Market storage m = _markets[marketId];
        if (msg.sender != m.oracle) revert NotOracle();
        if (block.timestamp < m.resolutionTime) revert ResolutionTooEarly();
        if (_outcome == Outcome.UNRESOLVED) revert InvalidOutcome();
        require(m.status == Status.Active || m.status == Status.Halted, "Cannot resolve");

        m.outcome = _outcome;
        m.status  = Status.Resolved;

        emit MarketResolved(marketId, _outcome);
    }

    /// @notice Owner emergency-resolves a market 30 days after resolutionTime.
    function emergencyResolve(uint256 marketId, Outcome _outcome) external onlyOwner {
        if (marketId >= _marketCount) revert MarketDoesNotExist(marketId);
        Market storage m = _markets[marketId];
        if (block.timestamp < m.resolutionTime + EMERGENCY_DELAY) revert EmergencyTooEarly();
        if (_outcome == Outcome.UNRESOLVED) revert InvalidOutcome();
        require(m.status != Status.Resolved, "Already resolved");

        m.outcome = _outcome;
        m.status  = Status.Resolved;

        emit MarketResolved(marketId, _outcome);
    }

    // -----------------------------------------------------------------------
    //  Redemption
    // -----------------------------------------------------------------------

    /// @notice Burn winning tokens and receive USDC.
    ///         YES wins  -> burn YES, receive 1 USDC each.
    ///         NO  wins  -> burn NO,  receive 1 USDC each.
    ///         INVALID   -> burn any held tokens, proportional refund.
    function redeemWinnings(uint256 marketId) external nonReentrant {
        if (marketId >= _marketCount) revert MarketDoesNotExist(marketId);
        Market storage m = _markets[marketId];
        if (m.status != Status.Resolved) revert MarketNotResolved(marketId);
        if (_redeemed[marketId][msg.sender]) revert AlreadyRedeemed();

        uint128 payout;
        Outcome o = m.outcome;

        if (o == Outcome.YES) {
            uint128 bal = uint128(balanceOf(msg.sender, yesTokenId(marketId)));
            if (bal == 0) revert NothingToRedeem();
            _burn(msg.sender, yesTokenId(marketId), bal);
            m.totalYesSupply -= bal;
            payout = bal; // 1 USDC per YES token
        } else if (o == Outcome.NO) {
            uint128 bal = uint128(balanceOf(msg.sender, noTokenId(marketId)));
            if (bal == 0) revert NothingToRedeem();
            _burn(msg.sender, noTokenId(marketId), bal);
            m.totalNoSupply -= bal;
            payout = bal; // 1 USDC per NO token
        } else {
            // INVALID — proportional refund based on total collateral / total tokens
            uint128 yesBal = uint128(balanceOf(msg.sender, yesTokenId(marketId)));
            uint128 noBal  = uint128(balanceOf(msg.sender, noTokenId(marketId)));
            uint128 total  = yesBal + noBal;
            if (total == 0) revert NothingToRedeem();

            uint256 totalTokens = uint256(m.totalYesSupply) + uint256(m.totalNoSupply);
            payout = uint128((uint256(total) * uint256(m.totalCollateral)) / totalTokens);

            if (yesBal > 0) {
                _burn(msg.sender, yesTokenId(marketId), yesBal);
                m.totalYesSupply -= yesBal;
            }
            if (noBal > 0) {
                _burn(msg.sender, noTokenId(marketId), noBal);
                m.totalNoSupply -= noBal;
            }
        }

        _redeemed[marketId][msg.sender] = true;
        m.totalCollateral -= payout;
        usdc.safeTransfer(msg.sender, payout);

        emit WinningsRedeemed(marketId, msg.sender, payout);
    }

    // -----------------------------------------------------------------------
    //  View Functions
    // -----------------------------------------------------------------------

    /// @notice Return the full Market struct for a given ID.
    function getMarket(uint256 marketId) external view returns (Market memory) {
        if (marketId >= _marketCount) revert MarketDoesNotExist(marketId);
        return _markets[marketId];
    }

    /// @notice YES token ID for a market.
    function yesTokenId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2;
    }

    /// @notice NO token ID for a market.
    function noTokenId(uint256 marketId) public pure returns (uint256) {
        return marketId * 2 + 1;
    }

    /// @notice Total number of markets created.
    function getMarketCount() external view returns (uint256) {
        return _marketCount;
    }
}
