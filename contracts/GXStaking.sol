// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GXStaking
 * @author GX Exchange — forked from Synthetix StakingRewards.sol
 * @notice Stake GX tokens, earn dual rewards (USDC fees + GX emissions),
 *         unlock fee discounts based on staking tier.
 *
 * @dev Key differences from Synthetix original:
 *  - Solidity 0.8.27 (native overflow, no SafeMath)
 *  - Two reward tokens (multi-reward pattern)
 *  - Four staking tiers with fee-discount schedule
 *  - 7-day cooldown before unstaking
 *  - IMMUTABLE — no admin functions to change core logic post-deploy
 *  - OpenZeppelin v5 Ownable + ReentrancyGuard
 */
contract GXStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ======================================================================
       TYPES
       ====================================================================== */

    /// @notice Staking tier thresholds and fee discounts.
    enum Tier {
        None,      // < 1,000 GX   — 0% discount
        Bronze,    // >= 1,000 GX  — 5% discount
        Silver,    // >= 10,000 GX — 10% discount
        Gold,      // >= 50,000 GX — 20% discount
        Platinum   // >= 100,000 GX — 30% discount
    }

    /// @notice Per-reward-token accounting (Synthetix multi-reward pattern).
    struct RewardData {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    /// @notice Per-user cooldown state.
    struct CooldownInfo {
        uint256 cooldownStart; // timestamp when cooldown was initiated
        uint256 amount;        // amount queued for withdrawal
    }

    /* ======================================================================
       CONSTANTS (IMMUTABLE POLICY)
       ====================================================================== */

    /// @notice Cooldown period before an unstake can be executed.
    uint256 public constant COOLDOWN_PERIOD = 7 days;

    /// @notice Default reward epoch length.
    uint256 public constant REWARDS_DURATION = 7 days;

    /// @notice Tier thresholds (18-decimal GX).
    uint256 public constant TIER_BRONZE   =   1_000 * 1e18;
    uint256 public constant TIER_SILVER   =  10_000 * 1e18;
    uint256 public constant TIER_GOLD     =  50_000 * 1e18;
    uint256 public constant TIER_PLATINUM = 100_000 * 1e18;

    /// @notice Fee discounts per tier (basis points, 10000 = 100%).
    uint256 public constant DISCOUNT_NONE     =    0; // 0%
    uint256 public constant DISCOUNT_BRONZE   =  500; // 5%
    uint256 public constant DISCOUNT_SILVER   = 1000; // 10%
    uint256 public constant DISCOUNT_GOLD     = 2000; // 20%
    uint256 public constant DISCOUNT_PLATINUM = 3000; // 30%

    /* ======================================================================
       IMMUTABLE STATE (set once in constructor)
       ====================================================================== */

    /// @notice The GX token used for staking.
    IERC20 public immutable stakingToken;

    /// @notice Primary reward token (USDC — protocol fee share).
    IERC20 public immutable rewardTokenA;

    /// @notice Secondary reward token (GX — emissions).
    IERC20 public immutable rewardTokenB;

    /// @notice Address authorised to notify new reward amounts.
    ///         Set once in constructor, cannot be changed.
    address public immutable rewardsDistributor;

    /* ======================================================================
       STORAGE — REWARD ACCOUNTING
       ====================================================================== */

    /// @dev reward token address => RewardData
    mapping(IERC20 => RewardData) public rewardData;

    /// @dev reward token => user => rewardPerTokenPaid snapshot
    mapping(IERC20 => mapping(address => uint256)) public userRewardPerTokenPaid;

    /// @dev reward token => user => accrued but unclaimed rewards
    mapping(IERC20 => mapping(address => uint256)) public rewards;

    /* ======================================================================
       STORAGE — STAKING
       ====================================================================== */

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    /// @dev user => cooldown info
    mapping(address => CooldownInfo) public cooldowns;

    /* ======================================================================
       EVENTS
       ====================================================================== */

    event Staked(address indexed user, uint256 amount, Tier tier);
    event CooldownInitiated(address indexed user, uint256 amount, uint256 cooldownEnd);
    event Withdrawn(address indexed user, uint256 amount, Tier tier);
    event RewardPaid(address indexed user, address indexed rewardToken, uint256 amount);
    event RewardAdded(address indexed rewardToken, uint256 amount);
    event CooldownCancelled(address indexed user, uint256 amount);

    /* ======================================================================
       ERRORS
       ====================================================================== */

    error ZeroAmount();
    error CooldownNotElapsed(uint256 readyAt);
    error NoCooldownActive();
    error InsufficientBalance(uint256 requested, uint256 available);
    error OnlyRewardsDistributor();
    error RewardTooHigh();
    error InvalidRewardToken();

    /* ======================================================================
       CONSTRUCTOR
       ====================================================================== */

    /**
     * @param _owner           Initial owner (receives no special upgrade power).
     * @param _rewardsDistributor Address that can call notifyRewardAmount.
     * @param _stakingToken    GX token address.
     * @param _rewardTokenA    Primary reward token (USDC).
     * @param _rewardTokenB    Secondary reward token (GX emissions).
     */
    constructor(
        address _owner,
        address _rewardsDistributor,
        address _stakingToken,
        address _rewardTokenA,
        address _rewardTokenB
    ) Ownable(_owner) {
        rewardsDistributor = _rewardsDistributor;
        stakingToken = IERC20(_stakingToken);
        rewardTokenA = IERC20(_rewardTokenA);
        rewardTokenB = IERC20(_rewardTokenB);
    }

    /* ======================================================================
       MODIFIERS
       ====================================================================== */

    modifier onlyRewardsDistributor() {
        if (msg.sender != rewardsDistributor) revert OnlyRewardsDistributor();
        _;
    }

    /// @dev Updates reward accounting for both tokens before executing the body.
    modifier updateReward(address account) {
        _updateReward(rewardTokenA, account);
        _updateReward(rewardTokenB, account);
        _;
    }

    /* ======================================================================
       VIEW FUNCTIONS
       ====================================================================== */

    /// @notice Total GX staked across all users.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Staked GX balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Current tier of `account` based on staked balance.
    function getTier(address account) public view returns (Tier) {
        return _tierOf(_balances[account]);
    }

    /// @notice Fee discount for `account` in basis points.
    function getFeeDiscount(address account) external view returns (uint256) {
        return _discountOf(_tierOf(_balances[account]));
    }

    /// @notice Last timestamp at which rewards are applicable for `token`.
    function lastTimeRewardApplicable(IERC20 token) public view returns (uint256) {
        RewardData storage rd = rewardData[token];
        return block.timestamp < rd.periodFinish ? block.timestamp : rd.periodFinish;
    }

    /// @notice Accumulated reward per staked token for `token`.
    function rewardPerToken(IERC20 token) public view returns (uint256) {
        RewardData storage rd = rewardData[token];
        if (_totalSupply == 0) {
            return rd.rewardPerTokenStored;
        }
        return rd.rewardPerTokenStored +
            ((lastTimeRewardApplicable(token) - rd.lastUpdateTime) * rd.rewardRate * 1e18) / _totalSupply;
    }

    /// @notice Unclaimed rewards of `account` for `token`.
    function earned(address account, IERC20 token) public view returns (uint256) {
        return
            (_balances[account] * (rewardPerToken(token) - userRewardPerTokenPaid[token][account])) / 1e18
            + rewards[token][account];
    }

    /// @notice Total reward emitted over the current epoch for `token`.
    function getRewardForDuration(IERC20 token) external view returns (uint256) {
        return rewardData[token].rewardRate * REWARDS_DURATION;
    }

    /* ======================================================================
       MUTATIVE FUNCTIONS — STAKING
       ====================================================================== */

    /**
     * @notice Stake GX tokens. Increases staked balance and may promote tier.
     * @param amount Amount of GX to stake (18 decimals).
     */
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        _totalSupply += amount;
        _balances[msg.sender] += amount;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, _tierOf(_balances[msg.sender]));
    }

    /**
     * @notice Initiate the 7-day cooldown before withdrawing.
     * @param amount Amount of GX to queue for unstaking.
     */
    function initiateCooldown(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (amount > _balances[msg.sender]) {
            revert InsufficientBalance(amount, _balances[msg.sender]);
        }

        CooldownInfo storage cd = cooldowns[msg.sender];

        // If an existing cooldown is active, merge amounts and restart timer
        cd.amount += amount;
        cd.cooldownStart = block.timestamp;

        emit CooldownInitiated(msg.sender, cd.amount, block.timestamp + COOLDOWN_PERIOD);
    }

    /**
     * @notice Cancel an active cooldown and keep tokens staked.
     */
    function cancelCooldown() external nonReentrant {
        CooldownInfo storage cd = cooldowns[msg.sender];
        if (cd.amount == 0) revert NoCooldownActive();

        uint256 cancelled = cd.amount;
        cd.amount = 0;
        cd.cooldownStart = 0;

        emit CooldownCancelled(msg.sender, cancelled);
    }

    /**
     * @notice Withdraw staked GX after cooldown has elapsed.
     *         Withdraws the full cooldown amount.
     */
    function withdraw() public nonReentrant updateReward(msg.sender) {
        CooldownInfo storage cd = cooldowns[msg.sender];
        if (cd.amount == 0) revert NoCooldownActive();

        uint256 readyAt = cd.cooldownStart + COOLDOWN_PERIOD;
        if (block.timestamp < readyAt) revert CooldownNotElapsed(readyAt);

        uint256 amount = cd.amount;

        // Clear cooldown
        cd.amount = 0;
        cd.cooldownStart = 0;

        // Update balances
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;

        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, _tierOf(_balances[msg.sender]));
    }

    /**
     * @notice Claim all accrued rewards for both reward tokens.
     */
    function getReward() public nonReentrant updateReward(msg.sender) {
        _claimReward(rewardTokenA, msg.sender);
        _claimReward(rewardTokenB, msg.sender);
    }

    /**
     * @notice Withdraw (after cooldown) and claim all rewards in one tx.
     */
    function exit() external {
        withdraw();
        getReward();
    }

    /* ======================================================================
       RESTRICTED FUNCTIONS — REWARD DISTRIBUTION
       ====================================================================== */

    /**
     * @notice Notify the contract of a new reward amount for a given token.
     *         Only callable by the immutable rewardsDistributor.
     * @param token  Must be rewardTokenA or rewardTokenB.
     * @param amount Amount of reward tokens being added for the new epoch.
     */
    function notifyRewardAmount(IERC20 token, uint256 amount)
        external
        onlyRewardsDistributor
        updateReward(address(0))
    {
        if (token != rewardTokenA && token != rewardTokenB) revert InvalidRewardToken();

        RewardData storage rd = rewardData[token];

        if (block.timestamp >= rd.periodFinish) {
            rd.rewardRate = amount / REWARDS_DURATION;
        } else {
            uint256 remaining = rd.periodFinish - block.timestamp;
            uint256 leftover = remaining * rd.rewardRate;
            rd.rewardRate = (amount + leftover) / REWARDS_DURATION;
        }

        // Solvency check — reward rate must be sustainable from contract balance
        uint256 balance = token.balanceOf(address(this));
        // For the staking token (GX = rewardTokenB), exclude staked amounts
        if (token == rewardTokenB) {
            balance -= _totalSupply;
        }
        if (rd.rewardRate > balance / REWARDS_DURATION) revert RewardTooHigh();

        rd.lastUpdateTime = block.timestamp;
        rd.periodFinish = block.timestamp + REWARDS_DURATION;

        emit RewardAdded(address(token), amount);
    }

    /* ======================================================================
       OWNER FUNCTIONS (limited — no core-logic changes)
       ====================================================================== */

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     *         Cannot recover the staking token or either reward token.
     * @param tokenAddress Token to recover.
     * @param tokenAmount  Amount to recover.
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot recover staking token");
        require(tokenAddress != address(rewardTokenA), "Cannot recover reward token A");
        require(tokenAddress != address(rewardTokenB), "Cannot recover reward token B");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
    }

    /* ======================================================================
       INTERNAL HELPERS
       ====================================================================== */

    /// @dev Update reward accounting for a single token.
    function _updateReward(IERC20 token, address account) private {
        RewardData storage rd = rewardData[token];
        rd.rewardPerTokenStored = rewardPerToken(token);
        rd.lastUpdateTime = lastTimeRewardApplicable(token);
        if (account != address(0)) {
            rewards[token][account] = earned(account, token);
            userRewardPerTokenPaid[token][account] = rd.rewardPerTokenStored;
        }
    }

    /// @dev Transfer accrued rewards for a single token to the user.
    function _claimReward(IERC20 token, address account) private {
        uint256 reward = rewards[token][account];
        if (reward > 0) {
            rewards[token][account] = 0;
            token.safeTransfer(account, reward);
            emit RewardPaid(account, address(token), reward);
        }
    }

    /// @dev Determine tier from staked amount.
    function _tierOf(uint256 amount) private pure returns (Tier) {
        if (amount >= TIER_PLATINUM) return Tier.Platinum;
        if (amount >= TIER_GOLD)     return Tier.Gold;
        if (amount >= TIER_SILVER)   return Tier.Silver;
        if (amount >= TIER_BRONZE)   return Tier.Bronze;
        return Tier.None;
    }

    /// @dev Map tier to fee discount in basis points.
    function _discountOf(Tier tier) private pure returns (uint256) {
        if (tier == Tier.Platinum) return DISCOUNT_PLATINUM;
        if (tier == Tier.Gold)     return DISCOUNT_GOLD;
        if (tier == Tier.Silver)   return DISCOUNT_SILVER;
        if (tier == Tier.Bronze)   return DISCOUNT_BRONZE;
        return DISCOUNT_NONE;
    }
}
