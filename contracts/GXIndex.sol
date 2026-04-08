// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GXIndex
 * @author GX Exchange
 * @notice On-chain crypto index token that holds REAL underlying ERC-20 tokens in custody.
 *         Users deposit USDC -> contract buys a basket of tokens -> mints index tokens.
 *         Users burn index tokens -> contract sells basket -> returns USDC.
 *         Monthly rebalancing by authorized rebalancer address.
 *
 * @dev    Swap logic uses placeholder functions marked with TODO comments where
 *         GXCore orderbook router integration will be connected.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract GXIndex is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Structs ─────────────────────────────────────────────────────────

    struct Component {
        address token;           // ERC-20 token address
        uint256 targetWeightBps; // Target weight in basis points (7700 = 77%)
        uint8 decimals;          // Token decimals for normalization
    }

    // ── State ───────────────────────────────────────────────────────────

    Component[] public components;

    address public usdc;              // USDC address for deposits/withdrawals
    address public rebalancer;        // Address authorized to rebalance
    address public gxcoreRouter;      // GXCore orderbook router for swaps (future)
    address public feeRecipient;      // Where management/mint/burn fees accrue

    uint256 public managementFeeBps;  // Annual management fee (50 = 0.50%)
    uint256 public mintFeeBps;        // Per-mint fee in bps (10 = 0.10%)
    uint256 public burnFeeBps;        // Per-burn fee in bps (10 = 0.10%)
    uint256 public lastFeeAccrual;    // Timestamp of last fee collection

    uint256 public constant MAX_COMPONENTS = 30;
    uint256 public constant BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365.25 days;

    // Price oracle placeholder: token => USDC price (scaled to 1e18)
    // In production this would come from Chainlink / GXCore engine
    mapping(address => uint256) public tokenPriceUsdc;

    // ── Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error TooManyComponents();
    error WeightsSumInvalid();
    error ComponentNotFound();
    error NotRebalancer();
    error NotFullyBacked();
    error InvalidWeightsLength();
    error DuplicateComponent();
    error InsufficientNav();

    // ── Events ──────────────────────────────────────────────────────────

    event Minted(address indexed user, uint256 usdcAmount, uint256 indexTokens);
    event Burned(address indexed user, uint256 indexTokens, uint256 usdcReturned);
    event Rebalanced(uint256 timestamp, uint256 tradesExecuted);
    event FeeAccrued(uint256 amount, uint256 timestamp);
    event ComponentAdded(address token, uint256 weightBps);
    event ComponentRemoved(address token);
    event WeightsUpdated(uint256 timestamp);
    event PriceUpdated(address indexed token, uint256 price);
    event GXCoreRouterUpdated(address indexed router);
    event FeeRecipientUpdated(address indexed recipient);

    // ── Modifiers ───────────────────────────────────────────────────────

    modifier onlyRebalancer() {
        if (msg.sender != rebalancer && msg.sender != owner()) revert NotRebalancer();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────

    /**
     * @param _name          Index token name (e.g. "GX Crypto Index 10")
     * @param _symbol        Index token symbol (e.g. "GXI10")
     * @param _usdc          USDC token address on this chain
     * @param _rebalancer    Address permitted to trigger rebalancing
     * @param _managementFee Annual management fee in bps
     * @param _mintFee       Per-mint fee in bps
     * @param _burnFee       Per-burn fee in bps
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _usdc,
        address _rebalancer,
        uint256 _managementFee,
        uint256 _mintFee,
        uint256 _burnFee
    )
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        if (_usdc == address(0)) revert ZeroAddress();

        usdc = _usdc;
        rebalancer = _rebalancer;
        managementFeeBps = _managementFee;
        mintFeeBps = _mintFee;
        burnFeeBps = _burnFee;
        feeRecipient = msg.sender;
        lastFeeAccrual = block.timestamp;
    }

    // ══════════════════════════════════════════════════════════════════
    //  MINT — Deposit USDC, receive index tokens
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDC and receive proportional index tokens.
     * @dev    Flow: take USDC -> deduct mint fee -> buy basket components -> mint tokens.
     *         Swap logic is placeholder — in production, GXCore router executes real swaps.
     * @param usdcAmount Amount of USDC to deposit (6-decimal atomic units)
     */
    function mint(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();

        // 1. Pull USDC from user
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Deduct mint fee
        uint256 fee = (usdcAmount * mintFeeBps) / BPS;
        uint256 netUsdc = usdcAmount - fee;
        if (fee > 0 && feeRecipient != address(0)) {
            IERC20(usdc).safeTransfer(feeRecipient, fee);
        }

        // 3. Buy basket components proportionally
        //    TODO: Replace with GXCore router swaps in production
        _buyBasket(netUsdc);

        // 4. Calculate index tokens to mint
        //    If first mint (no supply), 1 USDC = 1 index token (scaled to 18 decimals)
        uint256 tokensToMint;
        uint256 currentSupply = totalSupply();

        if (currentSupply == 0) {
            // Bootstrap: 1 USDC (6 dec) = 1 index token (18 dec)
            tokensToMint = netUsdc * 1e12; // scale 6 -> 18 decimals
        } else {
            // Pro-rata: tokens = (netUsdc / totalAUM) * totalSupply
            uint256 aum = totalAum();
            if (aum == 0) revert InsufficientNav();
            tokensToMint = (netUsdc * currentSupply) / aum;
        }

        // 5. Mint index tokens to user
        _mint(msg.sender, tokensToMint);

        emit Minted(msg.sender, usdcAmount, tokensToMint);
    }

    // ══════════════════════════════════════════════════════════════════
    //  BURN — Return index tokens, receive USDC
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Burn index tokens and receive proportional USDC.
     * @dev    Flow: burn tokens -> sell basket components -> deduct burn fee -> send USDC.
     * @param indexTokenAmount Amount of index tokens to burn (18 decimals)
     */
    function burn(uint256 indexTokenAmount) external nonReentrant {
        if (indexTokenAmount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < indexTokenAmount) revert ZeroAmount();

        uint256 currentSupply = totalSupply();

        // 1. Calculate proportional share of AUM
        uint256 aum = totalAum();
        uint256 grossUsdc = (indexTokenAmount * aum) / currentSupply;

        // 2. Burn index tokens
        _burn(msg.sender, indexTokenAmount);

        // 3. Sell basket components proportionally
        //    TODO: Replace with GXCore router swaps in production
        _sellBasket(grossUsdc);

        // 4. Deduct burn fee
        uint256 fee = (grossUsdc * burnFeeBps) / BPS;
        uint256 netUsdc = grossUsdc - fee;
        if (fee > 0 && feeRecipient != address(0)) {
            IERC20(usdc).safeTransfer(feeRecipient, fee);
        }

        // 5. Send USDC to user
        IERC20(usdc).safeTransfer(msg.sender, netUsdc);

        emit Burned(msg.sender, indexTokenAmount, netUsdc);
    }

    // ══════════════════════════════════════════════════════════════════
    //  REBALANCE — Monthly rebalancing of component weights
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Rebalance the index portfolio to match target weights.
     * @dev    Only callable by the rebalancer or owner.
     *         Accrues management fee before rebalancing.
     */
    function rebalance() external onlyRebalancer {
        // Accrue any outstanding management fees first
        accrueManagementFee();

        uint256 aum = totalAum();
        uint256 tradesExecuted = 0;

        for (uint256 i = 0; i < components.length; i++) {
            Component memory comp = components[i];
            uint256 currentValue = getComponentValue(i);
            uint256 targetValue = (aum * comp.targetWeightBps) / BPS;

            if (currentValue < targetValue) {
                // Under-weight: need to buy more of this token
                uint256 deficit = targetValue - currentValue;
                // TODO: Execute buy via GXCore router
                //   gxcoreRouter.swap(usdc, comp.token, deficit);
                tradesExecuted++;
            } else if (currentValue > targetValue) {
                // Over-weight: need to sell some of this token
                uint256 surplus = currentValue - targetValue;
                // TODO: Execute sell via GXCore router
                //   gxcoreRouter.swap(comp.token, usdc, surplus);
                tradesExecuted++;
            }
            // If equal, no trade needed
        }

        emit Rebalanced(block.timestamp, tradesExecuted);
    }

    // ══════════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Net Asset Value per index token, denominated in USDC (6 decimals).
     * @return NAV per token in USDC atomic units
     */
    function nav() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        // totalAum() returns USDC (6 dec), supply is 18 dec
        // nav = totalAum * 1e18 / supply => result in 6 dec USDC
        return (totalAum() * 1e18) / supply;
    }

    /**
     * @notice Total Assets Under Management in USDC terms (6 decimals).
     * @return Sum of all component values in USDC
     */
    function totalAum() public view returns (uint256) {
        uint256 aum = 0;
        for (uint256 i = 0; i < components.length; i++) {
            aum += getComponentValue(i);
        }
        // Also include any idle USDC held by the contract
        aum += IERC20(usdc).balanceOf(address(this));
        return aum;
    }

    /**
     * @notice Get all components of the index.
     * @return Array of Component structs
     */
    function getComponents() external view returns (Component[] memory) {
        return components;
    }

    /**
     * @notice Get the number of components in the index.
     */
    function getComponentCount() external view returns (uint256) {
        return components.length;
    }

    /**
     * @notice Value of a single component in USDC (6 decimals).
     * @param index Index in the components array
     * @return Value in USDC atomic units
     */
    function getComponentValue(uint256 index) public view returns (uint256) {
        Component memory comp = components[index];
        uint256 balance = IERC20(comp.token).balanceOf(address(this));

        // Price is stored as USDC per whole token, scaled to 1e18
        // value = balance * price / 10^(decimals) / 1e18 * 1e6
        // Simplified: value = balance * price / 10^(decimals + 12)
        uint256 price = tokenPriceUsdc[comp.token];
        if (price == 0) return 0;

        // balance is in token atomic units (10^decimals)
        // price is USDC-per-token scaled to 1e18
        // result should be USDC in 6 decimals
        // value = (balance * price) / (10^decimals * 10^12)
        //       = (balance * price) / 10^(decimals + 12)
        return (balance * price) / (10 ** (uint256(comp.decimals) + 12));
    }

    /**
     * @notice Check if every component has a non-zero balance in the contract.
     * @return True if all components have balance > 0
     */
    function isFullyBacked() public view returns (bool) {
        for (uint256 i = 0; i < components.length; i++) {
            if (IERC20(components[i].token).balanceOf(address(this)) == 0) {
                return false;
            }
        }
        return true;
    }

    // ══════════════════════════════════════════════════════════════════
    //  ADMIN — Component Management
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Add a new component to the index.
     * @param token     ERC-20 token address
     * @param weightBps Target weight in basis points
     * @param _decimals Token decimal places
     */
    function addComponent(address token, uint256 weightBps, uint8 _decimals) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (components.length >= MAX_COMPONENTS) revert TooManyComponents();

        // Check for duplicates
        for (uint256 i = 0; i < components.length; i++) {
            if (components[i].token == token) revert DuplicateComponent();
        }

        components.push(Component({
            token: token,
            targetWeightBps: weightBps,
            decimals: _decimals
        }));

        emit ComponentAdded(token, weightBps);
    }

    /**
     * @notice Remove a component from the index (swap-and-pop).
     * @param index Index in the components array to remove
     */
    function removeComponent(uint256 index) external onlyOwner {
        if (index >= components.length) revert ComponentNotFound();

        address removedToken = components[index].token;

        // Swap with last element and pop
        uint256 lastIndex = components.length - 1;
        if (index != lastIndex) {
            components[index] = components[lastIndex];
        }
        components.pop();

        emit ComponentRemoved(removedToken);
    }

    /**
     * @notice Update target weights for all components. Must sum to BPS (10000).
     * @param newWeightsBps Array of new weights, one per component
     */
    function updateWeights(uint256[] calldata newWeightsBps) external onlyOwner {
        if (newWeightsBps.length != components.length) revert InvalidWeightsLength();

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < newWeightsBps.length; i++) {
            totalWeight += newWeightsBps[i];
        }
        if (totalWeight != BPS) revert WeightsSumInvalid();

        for (uint256 i = 0; i < newWeightsBps.length; i++) {
            components[i].targetWeightBps = newWeightsBps[i];
        }

        emit WeightsUpdated(block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════
    //  ADMIN — Configuration
    // ══════════════════════════════════════════════════════════════════

    function setRebalancer(address _rebalancer) external onlyOwner {
        if (_rebalancer == address(0)) revert ZeroAddress();
        rebalancer = _rebalancer;
    }

    function setGXCoreRouter(address _router) external onlyOwner {
        gxcoreRouter = _router;
        emit GXCoreRouterUpdated(_router);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    function setFees(uint256 _managementFeeBps, uint256 _mintFeeBps, uint256 _burnFeeBps) external onlyOwner {
        managementFeeBps = _managementFeeBps;
        mintFeeBps = _mintFeeBps;
        burnFeeBps = _burnFeeBps;
    }

    /**
     * @notice Set the USDC-denominated price for a component token.
     * @dev    Placeholder oracle — in production use Chainlink or GXCore price feeds.
     * @param token Token address
     * @param price Price in USDC scaled to 1e18 (e.g. BTC at $60,000 = 60000 * 1e18)
     */
    function setTokenPrice(address token, uint256 price) external onlyOwner {
        tokenPriceUsdc[token] = price;
        emit PriceUpdated(token, price);
    }

    /**
     * @notice Batch-set prices for multiple tokens.
     */
    function setTokenPrices(address[] calldata tokens, uint256[] calldata prices) external onlyOwner {
        require(tokens.length == prices.length, "Length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenPriceUsdc[tokens[i]] = prices[i];
            emit PriceUpdated(tokens[i], prices[i]);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  MANAGEMENT FEE ACCRUAL
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Accrue the annual management fee by minting new index tokens to the fee recipient.
     * @dev    Management fee is expressed as an annualized rate. Fee is minted as new tokens,
     *         diluting existing holders proportionally. Can be called by anyone.
     *
     *         feeTokens = totalSupply * feeBps * elapsed / (BPS * SECONDS_PER_YEAR)
     */
    function accrueManagementFee() public {
        if (managementFeeBps == 0) return;
        if (totalSupply() == 0) {
            lastFeeAccrual = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed == 0) return;

        uint256 feeTokens = (totalSupply() * managementFeeBps * elapsed) / (BPS * SECONDS_PER_YEAR);

        lastFeeAccrual = block.timestamp;

        if (feeTokens > 0 && feeRecipient != address(0)) {
            _mint(feeRecipient, feeTokens);
            emit FeeAccrued(feeTokens, block.timestamp);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  EMERGENCY — Owner can recover stuck tokens
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Emergency recovery of tokens sent to this contract by mistake.
     * @dev    Cannot recover component tokens (those are the fund's assets).
     *         Only non-component, non-USDC tokens can be recovered.
     */
    function emergencyRecoverToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();

        // Prevent recovery of USDC or component tokens (fund assets)
        require(token != usdc, "Cannot recover USDC");
        for (uint256 i = 0; i < components.length; i++) {
            require(components[i].token != token, "Cannot recover component token");
        }

        IERC20(token).safeTransfer(to, amount);
    }

    // ══════════════════════════════════════════════════════════════════
    //  INTERNAL — Basket buy/sell (placeholder swap logic)
    // ══════════════════════════════════════════════════════════════════

    /**
     * @dev Buy basket components proportionally with USDC.
     *      PLACEHOLDER: In production, each swap routes through GXCore orderbook.
     *      For now, this is a no-op — USDC stays in the contract.
     *      The contract's totalAum() already counts idle USDC balance,
     *      so minting still works correctly for tracking purposes.
     *
     *      Production integration would look like:
     *        for each component:
     *          usdcForComponent = netUsdc * comp.targetWeightBps / BPS
     *          IGXCoreRouter(gxcoreRouter).swap(usdc, comp.token, usdcForComponent)
     */
    function _buyBasket(uint256 netUsdc) internal {
        // TODO: Integrate GXCore router for real swaps
        // For each component, buy proportionally:
        //
        // for (uint256 i = 0; i < components.length; i++) {
        //     Component memory comp = components[i];
        //     uint256 usdcForComp = (netUsdc * comp.targetWeightBps) / BPS;
        //     if (usdcForComp > 0 && gxcoreRouter != address(0)) {
        //         IERC20(usdc).safeApprove(gxcoreRouter, usdcForComp);
        //         IGXCoreRouter(gxcoreRouter).swap(usdc, comp.token, usdcForComp, 0);
        //     }
        // }

        // Placeholder: USDC remains in contract, counted in totalAum() via balanceOf
        (netUsdc); // silence unused variable warning
    }

    /**
     * @dev Sell basket components proportionally for USDC.
     *      PLACEHOLDER: In production, each swap routes through GXCore orderbook.
     *      For now, this is a no-op — assumes USDC is already available.
     *
     *      Production integration would look like:
     *        for each component:
     *          tokenAmount = proportional share of comp balance
     *          IGXCoreRouter(gxcoreRouter).swap(comp.token, usdc, tokenAmount)
     */
    function _sellBasket(uint256 usdcNeeded) internal {
        // TODO: Integrate GXCore router for real swaps
        // For each component, sell proportionally:
        //
        // uint256 aum = totalAum();
        // for (uint256 i = 0; i < components.length; i++) {
        //     Component memory comp = components[i];
        //     uint256 compBalance = IERC20(comp.token).balanceOf(address(this));
        //     uint256 sellAmount = (compBalance * usdcNeeded) / aum;
        //     if (sellAmount > 0 && gxcoreRouter != address(0)) {
        //         IERC20(comp.token).safeApprove(gxcoreRouter, sellAmount);
        //         IGXCoreRouter(gxcoreRouter).swap(comp.token, usdc, sellAmount, 0);
        //     }
        // }

        // Placeholder: assumes USDC is available in contract
        (usdcNeeded); // silence unused variable warning
    }
}
