// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GXVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ── Mock ERC-20 ─────────────────────────────────────────────────────────
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ── Mock non-standard ERC-20 (no return value on transfer) ──────────────
// FIX-6 test: SafeERC20 handles tokens that don't return bool
contract MockUSDT {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    // No return value — non-standard like real USDT
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ── Mock ArbSys precompile ──────────────────────────────────────────────
// FIX-7 test: deployed at address(0x64) via vm.etch
contract MockArbSys {
    uint256 private _blockNumber = 1000;

    function arbBlockNumber() external view returns (uint256) {
        return _blockNumber;
    }

    function setBlockNumber(uint256 n) external {
        _blockNumber = n;
    }
}

// ── Mock token that reverts on transferFrom ─────────────────────────────
// FIX-9 test: proves failed transfer reverts entire tx (no partial state)
contract RevertingToken {
    string public name = "Reverting Token";
    string public symbol = "RVRT";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // Always reverts — simulates a broken/paused token
    function transferFrom(address, address, uint256) external pure {
        revert("TOKEN_TRANSFER_FAILED");
    }

    function transfer(address, uint256) external pure {
        revert("TOKEN_TRANSFER_FAILED");
    }
}

// ════════════════════════════════════════════════════════════════════════
//  TEST SUITE
// ════════════════════════════════════════════════════════════════════════

contract GXVaultTest is Test {
    GXVault public vault;
    MockUSDC public usdc;
    MockUSDT public usdt;

    // Guardian private keys (deterministic for signing)
    uint256 constant G1_KEY = 0xA1;
    uint256 constant G2_KEY = 0xA2;
    uint256 constant G3_KEY = 0xA3;
    uint256 constant G4_KEY = 0xA4;
    uint256 constant G5_KEY = 0xA5;

    address g1;
    address g2;
    address g3;
    address g4;
    address g5;

    address owner = address(0xBEEF);
    address user1 = address(0xCAFE);
    address user2 = address(0xDEAD);

    uint256 constant MAX_DEPOSITS = 1_000_000e6; // 1M USDC
    uint256 constant DEPOSIT_AMT = 100e6;        // 100 USDC

    function setUp() public {
        // Derive guardian addresses from private keys
        g1 = vm.addr(G1_KEY);
        g2 = vm.addr(G2_KEY);
        g3 = vm.addr(G3_KEY);
        g4 = vm.addr(G4_KEY);
        g5 = vm.addr(G5_KEY);

        // Deploy mock ArbSys at the Arbitrum precompile address (FIX-7)
        MockArbSys arbSys = new MockArbSys();
        vm.etch(address(0x0000000000000000000000000000000000000064), address(arbSys).code);

        // Sort guardians ascending (required for signature verification)
        address[] memory guardiansSorted = _sortAddresses(g1, g2, g3, g4, g5);

        // Deploy vault with 5 guardians, require 4 sigs (strict >2/3 of 5 = need >3.33 → 4)
        vm.prank(owner);
        vault = new GXVault(guardiansSorted, 4, MAX_DEPOSITS);

        // Deploy mock tokens
        usdc = new MockUSDC();
        usdt = new MockUSDT();

        // Approve tokens
        vm.startPrank(owner);
        vault.addToken(address(usdc), 1e6);
        vault.addToken(address(usdt), 1e6);
        vm.stopPrank();

        // Fund user1 and approve vault
        usdc.mint(user1, 10_000e6);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════════
    //  DEPOSIT TESTS
    // ════════════════════════════════════════════════════════════════════

    function test_deposit_success() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        assertEq(vault.getBalance(address(usdc), user1), DEPOSIT_AMT);
        assertEq(vault.totalDeposited(), DEPOSIT_AMT);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMT);
    }

    function test_deposit_unapproved_token_reverts() public {
        MockUSDC fakeToken = new MockUSDC();
        fakeToken.mint(user1, DEPOSIT_AMT);
        vm.prank(user1);
        fakeToken.approve(address(vault), DEPOSIT_AMT);

        vm.expectRevert(GXVault.TokenNotApproved.selector);
        vm.prank(user1);
        vault.deposit(address(fakeToken), DEPOSIT_AMT);
    }

    function test_deposit_below_minimum_reverts() public {
        vm.expectRevert(GXVault.BelowMinimumDeposit.selector);
        vm.prank(user1);
        vault.deposit(address(usdc), 999); // < 1e6
    }

    function test_deposit_exceeds_cap_reverts() public {
        usdc.mint(user1, MAX_DEPOSITS + 1e6);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);

        // Deposit up to cap
        vm.prank(user1);
        vault.deposit(address(usdc), MAX_DEPOSITS);

        // Next deposit should fail
        vm.expectRevert(GXVault.DepositCapExceeded.selector);
        vm.prank(user1);
        vault.deposit(address(usdc), 1e6);
    }

    function test_deposit_emits_event() public {
        vm.expectEmit(true, true, false, true);
        emit GXVault.Deposited(user1, address(usdc), DEPOSIT_AMT, block.timestamp);

        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);
    }

    function test_deposit_when_paused_reverts() public {
        vm.prank(owner);
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-6: SafeERC20 — non-standard token (no return value)
    // ════════════════════════════════════════════════════════════════════

    function test_fix6_deposit_nonstandard_token() public {
        usdt.mint(user1, DEPOSIT_AMT);
        vm.prank(user1);
        usdt.approve(address(vault), DEPOSIT_AMT);

        // SafeERC20 should handle USDT's non-standard transferFrom (no bool return)
        vm.prank(user1);
        vault.deposit(address(usdt), DEPOSIT_AMT);

        assertEq(vault.getBalance(address(usdt), user1), DEPOSIT_AMT);
    }

    // ════════════════════════════════════════════════════════════════════
    //  WITHDRAWAL TESTS (queue + execute)
    // ════════════════════════════════════════════════════════════════════

    function test_withdrawal_full_lifecycle() public {
        // 1. Deposit
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        // 2. Queue withdrawal with guardian signatures
        bytes32 withdrawalId = keccak256("withdrawal-1");
        bytes[] memory sigs = _signWithdrawal(
            address(usdc), user1, DEPOSIT_AMT, withdrawalId
        );

        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);
        assertEq(vault.getPendingWithdrawalCount(), 1);

        // 3. Wait for timelock
        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);

        // 4. Execute
        uint256 balBefore = usdc.balanceOf(user1);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId);

        assertEq(usdc.balanceOf(user1), balBefore + DEPOSIT_AMT);
        assertEq(vault.getBalance(address(usdc), user1), 0);
        assertTrue(vault.processedWithdrawals(withdrawalId));
        assertEq(vault.getPendingWithdrawalCount(), 0);
    }

    function test_withdrawal_before_timelock_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("withdrawal-early");
        bytes[] memory sigs = _signWithdrawal(
            address(usdc), user1, DEPOSIT_AMT, withdrawalId
        );
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);

        // Try to execute immediately (timelock still active)
        vm.expectRevert(GXVault.WithdrawalTimelockActive.selector);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId);
    }

    function test_withdrawal_double_execute_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("double-exec");
        bytes[] memory sigs = _signWithdrawal(
            address(usdc), user1, DEPOSIT_AMT, withdrawalId
        );
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);

        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId);

        // Second execution reverts — details deleted so params don't match
        vm.expectRevert(GXVault.WithdrawalNotQueued.selector);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId);
    }

    function test_withdrawal_cancel_by_owner() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("cancel-me");
        bytes[] memory sigs = _signWithdrawal(
            address(usdc), user1, DEPOSIT_AMT, withdrawalId
        );
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);

        vm.prank(owner);
        vault.cancelWithdrawal(withdrawalId);

        assertEq(vault.withdrawalTimelocks(withdrawalId), 0);
        assertEq(vault.getPendingWithdrawalCount(), 0);
        // User balance untouched (deduction only happens at execute)
        assertEq(vault.getBalance(address(usdc), user1), DEPOSIT_AMT);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-3: Message validation in finalization
    // ════════════════════════════════════════════════════════════════════

    function test_fix3_execute_mismatched_params_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("fix3-test");
        bytes[] memory sigs = _signWithdrawal(
            address(usdc), user1, DEPOSIT_AMT, withdrawalId
        );
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);

        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);

        // Wrong token
        vm.expectRevert(GXVault.WithdrawalNotQueued.selector);
        vault.executeWithdrawal(address(usdt), user1, DEPOSIT_AMT, withdrawalId);

        // Wrong recipient
        vm.expectRevert(GXVault.WithdrawalNotQueued.selector);
        vault.executeWithdrawal(address(usdc), user2, DEPOSIT_AMT, withdrawalId);

        // Wrong amount
        vm.expectRevert(GXVault.WithdrawalNotQueued.selector);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT - 1, withdrawalId);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-4: Domain separator includes address(this)
    // ════════════════════════════════════════════════════════════════════

    function test_fix4_domain_separator_includes_contract_address() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("GXVault"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.DOMAIN_SEPARATOR(), expected);
    }

    function test_fix4_different_vaults_have_different_domains() public {
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(owner);
        GXVault vault2 = new GXVault(gs, 1, MAX_DEPOSITS);

        // Domain separators must differ because address(this) differs
        assertTrue(vault.DOMAIN_SEPARATOR() != vault2.DOMAIN_SEPARATOR());
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-5: Action prefix in signatures (typed hash)
    // ════════════════════════════════════════════════════════════════════

    function test_fix5_withdrawal_uses_typed_hash() public view {
        bytes32 expected = keccak256(
            "GXVaultWithdraw(address token,address to,uint256 amount,bytes32 withdrawalId)"
        );
        assertEq(vault.WITHDRAW_TYPEHASH(), expected);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-8: Strict >2/3 supermajority
    // ════════════════════════════════════════════════════════════════════

    function test_fix8_insufficient_sigs_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("fix8-test");

        // With 5 guardians, need sigs * 3 > 5 * 2 = 10, so need > 3.33 → 4 sigs
        // Try with only 3 sigs (3*3=9 <= 10, should fail)
        bytes[] memory threeSigs = _signWithdrawalForVault(
            vault, address(usdc), user1, DEPOSIT_AMT, withdrawalId,
            _pickKeys(3)
        );

        vm.expectRevert(GXVault.InvalidSignatureCount.selector);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, threeSigs);
    }

    function test_fix8_exact_twothirds_not_enough() public {
        // Deploy vault with 3 guardians — exactly 2/3 = 2 sigs. Strict >2/3 means need 3.
        address[] memory threeGuardians = _sortAddresses3(g1, g2, g3);
        vm.prank(owner);
        GXVault vault3 = new GXVault(threeGuardians, 3, MAX_DEPOSITS);

        vm.prank(owner);
        vault3.addToken(address(usdc), 1e6);

        usdc.mint(user1, DEPOSIT_AMT);
        vm.prank(user1);
        usdc.approve(address(vault3), DEPOSIT_AMT);
        vm.prank(user1);
        vault3.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("fix8-exact");

        // 2 sigs out of 3: 2*3=6 <= 3*2=6 → NOT strictly greater → should revert
        uint256[] memory twoKeys = new uint256[](2);
        (twoKeys[0], twoKeys[1]) = _sortTwoKeys(G1_KEY, G2_KEY);

        bytes[] memory twoSigs = _signWithdrawalForVault(
            vault3, address(usdc), user1, DEPOSIT_AMT, withdrawalId, twoKeys
        );

        vm.expectRevert(GXVault.InvalidSignatureCount.selector);
        vault3.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, twoSigs);
    }

    function test_fix8_supermajority_succeeds() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("fix8-pass");

        // 4 sigs out of 5: 4*3=12 > 5*2=10 → passes
        bytes[] memory sigs = _signWithdrawal(
            address(usdc), user1, DEPOSIT_AMT, withdrawalId
        );

        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);
        assertEq(vault.getPendingWithdrawalCount(), 1);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-8 cont: Duplicate signature detection
    // ════════════════════════════════════════════════════════════════════

    function test_duplicate_signature_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("dup-sig");
        bytes32 digest = _buildDigest(address(usdc), user1, DEPOSIT_AMT, withdrawalId);

        // Sign with same key twice
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(G1_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes[] memory dupSigs = new bytes[](4);
        dupSigs[0] = sig;
        dupSigs[1] = sig;
        dupSigs[2] = sig;
        dupSigs[3] = sig;

        vm.expectRevert(GXVault.DuplicateSignature.selector);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, dupSigs);
    }

    function test_non_guardian_signer_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("non-guardian");
        bytes32 digest = _buildDigest(address(usdc), user1, DEPOSIT_AMT, withdrawalId);

        // Sign with a non-guardian key
        uint256 fakeKey = 0xDEAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakeKey, digest);
        bytes memory fakeSig = abi.encodePacked(r, s, v);

        // Build 4 sigs with the fake one mixed in
        bytes[] memory sigs = new bytes[](4);
        sigs[0] = fakeSig;
        sigs[1] = fakeSig;
        sigs[2] = fakeSig;
        sigs[3] = fakeSig;

        vm.expectRevert(); // Either SignerNotGuardian or DuplicateSignature
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-2: Emergency pause cancels pending withdrawals
    // ════════════════════════════════════════════════════════════════════

    function test_fix2_emergency_pause_cancels_all_pending() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        // Queue two withdrawals
        bytes32 wId1 = keccak256("ep-1");
        bytes32 wId2 = keccak256("ep-2");

        bytes[] memory sigs1 = _signWithdrawal(address(usdc), user1, 50e6, wId1);
        bytes[] memory sigs2 = _signWithdrawal(address(usdc), user1, 50e6, wId2);

        vault.queueWithdrawal(address(usdc), user1, 50e6, wId1, sigs1);
        vault.queueWithdrawal(address(usdc), user1, 50e6, wId2, sigs2);
        assertEq(vault.getPendingWithdrawalCount(), 2);

        // Emergency pause
        vm.prank(owner);
        vault.emergencyPause();

        // All pending withdrawals should be cancelled
        assertEq(vault.getPendingWithdrawalCount(), 0);
        assertEq(vault.withdrawalTimelocks(wId1), 0);
        assertEq(vault.withdrawalTimelocks(wId2), 0);

        // User balance is preserved (deduction only at execute)
        assertEq(vault.getBalance(address(usdc), user1), DEPOSIT_AMT);

        // Vault is paused
        assertTrue(vault.paused());
    }

    function test_fix2_emergency_pause_prevents_execute_after() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 wId = keccak256("ep-execute");
        bytes[] memory sigs = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId, sigs);

        // Emergency pause
        vm.prank(owner);
        vault.emergencyPause();

        // Even if timelock has passed, can't execute (paused + cancelled)
        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId);
    }

    // ════════════════════════════════════════════════════════════════════
    //  ADMIN TESTS
    // ════════════════════════════════════════════════════════════════════

    function test_guardian_add_remove() public {
        address newGuardian = address(0xF00D);

        vm.prank(owner);
        vault.addGuardian(newGuardian);
        assertTrue(vault.guardians(newGuardian));
        assertEq(vault.guardianCount(), 6);

        vm.prank(owner);
        vault.removeGuardian(newGuardian);
        assertFalse(vault.guardians(newGuardian));
        assertEq(vault.guardianCount(), 5);
    }

    function test_add_guardian_zero_address_reverts() public {
        vm.expectRevert(GXVault.InvalidAddress.selector);
        vm.prank(owner);
        vault.addGuardian(address(0));
    }

    function test_add_duplicate_guardian_reverts() public {
        vm.expectRevert(GXVault.InvalidGuardian.selector);
        vm.prank(owner);
        vault.addGuardian(g1); // Already a guardian
    }

    function test_only_owner_can_admin() public {
        vm.expectRevert(GXVault.NotOwner.selector);
        vm.prank(user1);
        vault.addGuardian(address(0xF00D));

        vm.expectRevert(GXVault.NotOwner.selector);
        vm.prank(user1);
        vault.addToken(address(0xF00D), 1e6);

        vm.expectRevert(GXVault.NotOwner.selector);
        vm.prank(user1);
        vault.pause();

        vm.expectRevert(GXVault.NotOwner.selector);
        vm.prank(user1);
        vault.transferOwnership(user1);
    }

    function test_transfer_ownership() public {
        vm.prank(owner);
        vault.transferOwnership(user1);
        assertEq(vault.owner(), user1);

        // Old owner can't admin anymore
        vm.expectRevert(GXVault.NotOwner.selector);
        vm.prank(owner);
        vault.pause();
    }

    function test_transfer_ownership_to_zero_reverts() public {
        vm.expectRevert(GXVault.InvalidAddress.selector);
        vm.prank(owner);
        vault.transferOwnership(address(0));
    }

    function test_set_max_total_deposits() public {
        vm.prank(owner);
        vault.setMaxTotalDeposits(500_000e6);
        assertEq(vault.maxTotalDeposits(), 500_000e6);
    }

    function test_set_required_signatures() public {
        // Currently 4 of 5. Change to 5 of 5.
        vm.prank(owner);
        vault.setRequiredSignatures(5);
        assertEq(vault.requiredSignatures(), 5);
    }

    function test_set_required_signatures_invalid_reverts() public {
        vm.expectRevert(GXVault.InvalidSignatureCount.selector);
        vm.prank(owner);
        vault.setRequiredSignatures(0);

        vm.expectRevert(GXVault.InvalidSignatureCount.selector);
        vm.prank(owner);
        vault.setRequiredSignatures(6); // > guardianCount
    }

    function test_too_many_guardians_reverts() public {
        // Add guardians up to MAX_GUARDIANS
        vm.startPrank(owner);
        for (uint256 i = 1; i <= 15; i++) {
            vault.addGuardian(address(uint160(0xF000 + i)));
        }
        // Now at 20 guardians (5 initial + 15 added)
        assertEq(vault.guardianCount(), 20);

        vm.expectRevert(GXVault.TooManyGuardians.selector);
        vault.addGuardian(address(uint160(0xF100)));
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR VALIDATION
    // ════════════════════════════════════════════════════════════════════

    function test_constructor_empty_guardians_reverts() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(GXVault.InvalidGuardian.selector);
        new GXVault(empty, 1, MAX_DEPOSITS);
    }

    function test_constructor_zero_required_sigs_reverts() public {
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.expectRevert(GXVault.InvalidSignatureCount.selector);
        new GXVault(gs, 0, MAX_DEPOSITS);
    }

    function test_constructor_required_sigs_exceeds_guardians_reverts() public {
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.expectRevert(GXVault.InvalidSignatureCount.selector);
        new GXVault(gs, 2, MAX_DEPOSITS);
    }

    function test_constructor_duplicate_guardian_reverts() public {
        address[] memory gs = new address[](2);
        gs[0] = g1;
        gs[1] = g1; // duplicate
        vm.expectRevert(GXVault.DuplicateSignature.selector);
        new GXVault(gs, 1, MAX_DEPOSITS);
    }

    function test_constructor_zero_address_guardian_reverts() public {
        address[] memory gs = new address[](1);
        gs[0] = address(0);
        vm.expectRevert(GXVault.InvalidAddress.selector);
        new GXVault(gs, 1, MAX_DEPOSITS);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-1: No nested nonReentrant — internal helpers are plain
    // ════════════════════════════════════════════════════════════════════

    /**
     * @dev FIX-1 test: Proves the batch+internal pattern works.
     *      Queue 3 withdrawals, then execute all 3 sequentially.
     *      Each executeWithdrawal() is nonReentrant and calls _removePendingWithdrawal()
     *      (plain internal, no modifier).
     *
     *      The original Hyperliquid bug: both batchFinalize AND individual finalize
     *      had nonReentrant, so batch → finalize would revert with
     *      "ReentrancyGuard: reentrant call".
     *
     *      Our fix: only external entry points carry nonReentrant.
     *      Internal helpers (_removePendingWithdrawal, _cancelWithdrawalInternal,
     *      _verifyGuardianSignatures) have NO modifier.
     *      So this must succeed without reentrancy revert:
     */
    function test_fix1_multiple_executions_no_nested_reentrant() public {
        // Deposit enough for 3 withdrawals
        usdc.mint(user1, 300e6);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user1);
        vault.deposit(address(usdc), 300e6);

        // Queue 3 separate withdrawals
        bytes32 wId1 = keccak256("fix1-batch-1");
        bytes32 wId2 = keccak256("fix1-batch-2");
        bytes32 wId3 = keccak256("fix1-batch-3");

        bytes[] memory sigs1 = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId1);
        bytes[] memory sigs2 = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId2);
        bytes[] memory sigs3 = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId3);

        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId1, sigs1);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId2, sigs2);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId3, sigs3);
        assertEq(vault.getPendingWithdrawalCount(), 3);

        // Advance past timelock
        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);

        // Execute all 3 — each is nonReentrant, each calls _removePendingWithdrawal internally.
        // If internal helpers also had nonReentrant (the Hyperliquid bug), these would revert.
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId1);
        assertEq(vault.getPendingWithdrawalCount(), 2);

        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId2);
        assertEq(vault.getPendingWithdrawalCount(), 1);

        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId3);
        assertEq(vault.getPendingWithdrawalCount(), 0);

        // All 3 processed, balances zeroed, tokens returned
        assertEq(vault.getBalance(address(usdc), user1), 0);
        assertTrue(vault.processedWithdrawals(wId1));
        assertTrue(vault.processedWithdrawals(wId2));
        assertTrue(vault.processedWithdrawals(wId3));
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-7: ArbSys precompile mock — correct L2 block numbers
    // ════════════════════════════════════════════════════════════════════

    /**
     * @dev FIX-7 test: Proves vault.getBlockNumber() delegates to
     *      ArbSys(0x64).arbBlockNumber() and returns the L2 block,
     *      NOT the EVM block.number (which is the L1 batch number on Arbitrum).
     *
     *      Uses vm.mockCall to control the precompile response.
     */
    function test_fix7_getBlockNumber_uses_arbsys() public {
        address arbSysAddr = address(0x0000000000000000000000000000000000000064);

        // Mock ArbSys to return a specific L2 block number
        vm.mockCall(
            arbSysAddr,
            abi.encodeWithSignature("arbBlockNumber()"),
            abi.encode(uint256(42_000_000))
        );
        assertEq(vault.getBlockNumber(), 42_000_000);

        // Change mock to a different value — proves it reads from ArbSys, not block.number
        vm.mockCall(
            arbSysAddr,
            abi.encodeWithSignature("arbBlockNumber()"),
            abi.encode(uint256(99_999_999))
        );
        assertEq(vault.getBlockNumber(), 99_999_999);

        // Verify it does NOT equal the EVM block.number
        // (on Arbitrum, block.number is the L1 batch number, which differs from L2 block)
        assertTrue(vault.getBlockNumber() != block.number);

        vm.clearMockedCalls();
    }

    // ════════════════════════════════════════════════════════════════════
    //  FIX-9: Events emitted AFTER state changes, BEFORE external calls
    // ════════════════════════════════════════════════════════════════════

    /**
     * @dev FIX-9 test: Proves deposit is atomic — if the token transfer
     *      reverts, the entire transaction reverts. No partial state
     *      (no balance credited, no totalDeposited incremented, no event observable).
     *
     *      This catches the anti-pattern where state changes + event happen
     *      but the transfer at the end fails, leaving inconsistent state.
     *      With CEI + atomicity, a reverting transfer rolls back everything.
     */
    function test_fix9_deposit_reverts_atomically_on_failed_transfer() public {
        // Deploy a token that always reverts on transferFrom
        RevertingToken rvrt = new RevertingToken();
        vm.prank(owner);
        vault.addToken(address(rvrt), 1e6);

        rvrt.mint(user1, DEPOSIT_AMT);
        vm.prank(user1);
        rvrt.approve(address(vault), DEPOSIT_AMT);

        // Record state before
        uint256 totalBefore = vault.totalDeposited();
        uint256 balBefore = vault.getBalance(address(rvrt), user1);

        // Deposit MUST revert because transferFrom reverts
        vm.expectRevert("TOKEN_TRANSFER_FAILED");
        vm.prank(user1);
        vault.deposit(address(rvrt), DEPOSIT_AMT);

        // State is unchanged — atomicity guaranteed
        assertEq(vault.totalDeposited(), totalBefore, "totalDeposited must not change");
        assertEq(vault.getBalance(address(rvrt), user1), balBefore, "balance must not change");
    }

    /**
     * @dev FIX-9 continued: For a successful deposit, verify that both
     *      the event fired AND the actual token transfer happened.
     *      This proves the event reflects real state, not premature emission.
     */
    function test_fix9_deposit_event_matches_actual_transfer() public {
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        // Expect Deposited event with exact args
        vm.expectEmit(true, true, false, true);
        emit GXVault.Deposited(user1, address(usdc), DEPOSIT_AMT, block.timestamp);

        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        // The event amount (DEPOSIT_AMT) matches the actual transferred amount
        assertEq(
            usdc.balanceOf(address(vault)),
            vaultBalBefore + DEPOSIT_AMT,
            "vault must hold exactly the deposited amount"
        );
        assertEq(
            vault.getBalance(address(usdc), user1),
            DEPOSIT_AMT,
            "internal balance must match event amount"
        );
    }

    /**
     * @dev FIX-9 continued: Withdrawal event + transfer consistency.
     *      Verify Withdrawn event fires and user actually receives tokens.
     */
    function test_fix9_withdrawal_event_matches_actual_transfer() public {
        // Setup: deposit + queue + advance timelock
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 withdrawalId = keccak256("fix9-withdraw");
        bytes[] memory sigs = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId, sigs);
        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);

        uint256 userBalBefore = usdc.balanceOf(user1);

        // Expect Withdrawn event
        vm.expectEmit(true, true, false, true);
        emit GXVault.Withdrawn(address(usdc), user1, DEPOSIT_AMT, withdrawalId);

        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, withdrawalId);

        // User actually received the tokens (event amount == transfer amount)
        assertEq(
            usdc.balanceOf(user1),
            userBalBefore + DEPOSIT_AMT,
            "user must receive exactly the withdrawn amount"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    //  BRANCH COVERAGE: queueWithdrawal edge cases
    // ════════════════════════════════════════════════════════════════════

    function test_queue_withdrawal_to_zero_address_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 wId = keccak256("zero-to");
        bytes[] memory sigs = _signWithdrawal(address(usdc), address(0), DEPOSIT_AMT, wId);

        vm.expectRevert(GXVault.InvalidAddress.selector);
        vault.queueWithdrawal(address(usdc), address(0), DEPOSIT_AMT, wId, sigs);
    }

    function test_queue_withdrawal_already_processed_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 wId = keccak256("already-processed");
        bytes[] memory sigs = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId, sigs);

        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId);

        // Try to queue again with same ID — already processed
        usdc.mint(user1, DEPOSIT_AMT);
        vm.prank(user1);
        usdc.approve(address(vault), DEPOSIT_AMT);
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes[] memory sigs2 = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId);
        vm.expectRevert(GXVault.WithdrawalAlreadyProcessed.selector);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId, sigs2);
    }

    function test_queue_withdrawal_duplicate_pending_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 wId = keccak256("dup-pending");
        bytes[] memory sigs1 = _signWithdrawal(address(usdc), user1, 50e6, wId);
        vault.queueWithdrawal(address(usdc), user1, 50e6, wId, sigs1);

        // Try to queue same ID again (timelock != 0)
        bytes[] memory sigs2 = _signWithdrawal(address(usdc), user1, 50e6, wId);
        vm.expectRevert(GXVault.WithdrawalAlreadyProcessed.selector);
        vault.queueWithdrawal(address(usdc), user1, 50e6, wId, sigs2);
    }

    function test_queue_withdrawal_insufficient_balance_reverts() public {
        // user2 has no balance
        bytes32 wId = keccak256("no-balance");
        bytes[] memory sigs = _signWithdrawal(address(usdc), user2, DEPOSIT_AMT, wId);

        vm.expectRevert(GXVault.InsufficientBalance.selector);
        vault.queueWithdrawal(address(usdc), user2, DEPOSIT_AMT, wId, sigs);
    }

    // ════════════════════════════════════════════════════════════════════
    //  BRANCH COVERAGE: cancelWithdrawal edge cases
    // ════════════════════════════════════════════════════════════════════

    function test_cancel_nonexistent_withdrawal_reverts() public {
        bytes32 wId = keccak256("nonexistent");
        vm.expectRevert(GXVault.WithdrawalNotQueued.selector);
        vm.prank(owner);
        vault.cancelWithdrawal(wId);
    }

    function test_cancel_already_processed_withdrawal_reverts() public {
        vm.prank(user1);
        vault.deposit(address(usdc), DEPOSIT_AMT);

        bytes32 wId = keccak256("cancel-processed");
        bytes[] memory sigs = _signWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId);
        vault.queueWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId, sigs);

        vm.warp(block.timestamp + vault.WITHDRAWAL_DELAY() + 1);
        vault.executeWithdrawal(address(usdc), user1, DEPOSIT_AMT, wId);

        // Try to cancel — processedWithdrawals[wId] is true, timelock still non-zero
        vm.expectRevert(GXVault.WithdrawalAlreadyProcessed.selector);
        vm.prank(owner);
        vault.cancelWithdrawal(wId);
    }

    // ════════════════════════════════════════════════════════════════════
    //  BRANCH COVERAGE: admin edge cases
    // ════════════════════════════════════════════════════════════════════

    function test_remove_non_guardian_reverts() public {
        vm.expectRevert(GXVault.InvalidGuardian.selector);
        vm.prank(owner);
        vault.removeGuardian(address(0xF00D)); // not a guardian
    }

    function test_add_token_zero_address_reverts() public {
        vm.expectRevert(GXVault.InvalidAddress.selector);
        vm.prank(owner);
        vault.addToken(address(0), 1e6);
    }

    function test_constructor_too_many_guardians_reverts() public {
        address[] memory tooMany = new address[](21);
        for (uint256 i = 0; i < 21; i++) {
            tooMany[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(GXVault.TooManyGuardians.selector);
        new GXVault(tooMany, 1, MAX_DEPOSITS);
    }

    // ════════════════════════════════════════════════════════════════════
    //  BRANCH COVERAGE: executeWithdrawal edge cases
    // ════════════════════════════════════════════════════════════════════

    function test_execute_never_queued_withdrawal_reverts() public {
        // For a never-queued ID, _withdrawalDetails[id] is all zeros.
        // Passing (token=0, to=0, amount=0) matches the zero struct,
        // bypasses FIX-3 check (line 270), then hits timelockExpiry==0 (line 275).
        bytes32 wId = keccak256("never-queued");
        vm.expectRevert(GXVault.WithdrawalNotQueued.selector);
        vault.executeWithdrawal(address(0), address(0), 0, wId);
    }

    // ════════════════════════════════════════════════════════════════════
    //  PAUSE / UNPAUSE
    // ════════════════════════════════════════════════════════════════════

    function test_pause_unpause() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // ════════════════════════════════════════════════════════════════════
    //  HELPERS
    // ════════════════════════════════════════════════════════════════════

    function _buildDigest(
        address token,
        address to,
        uint256 amount,
        bytes32 withdrawalId
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(vault.WITHDRAW_TYPEHASH(), token, to, amount, withdrawalId)
        );
        return keccak256(
            abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash)
        );
    }

    /// @dev Sign withdrawal with 4 guardians sorted by address (ascending).
    function _signWithdrawal(
        address token,
        address to,
        uint256 amount,
        bytes32 withdrawalId
    ) internal view returns (bytes[] memory) {
        return _signWithdrawalForVault(vault, token, to, amount, withdrawalId, _pickKeys(4));
    }

    function _signWithdrawalForVault(
        GXVault v,
        address token,
        address to,
        uint256 amount,
        bytes32 withdrawalId,
        uint256[] memory keys
    ) internal view returns (bytes[] memory) {
        bytes32 structHash = keccak256(
            abi.encode(v.WITHDRAW_TYPEHASH(), token, to, amount, withdrawalId)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", v.DOMAIN_SEPARATOR(), structHash)
        );

        // Sort keys by their derived address (ascending) for duplicate detection
        _sortKeysByAddress(keys);

        bytes[] memory sigs = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            (uint8 v_, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v_);
        }
        return sigs;
    }

    /// @dev Pick first `n` guardian keys, sorted by address ascending.
    function _pickKeys(uint256 n) internal view returns (uint256[] memory) {
        uint256[] memory allKeys = new uint256[](5);
        allKeys[0] = G1_KEY;
        allKeys[1] = G2_KEY;
        allKeys[2] = G3_KEY;
        allKeys[3] = G4_KEY;
        allKeys[4] = G5_KEY;

        _sortKeysByAddress(allKeys);

        uint256[] memory picked = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            picked[i] = allKeys[i];
        }
        return picked;
    }

    /// @dev Sort private keys by their derived address (ascending). Simple insertion sort.
    function _sortKeysByAddress(uint256[] memory keys) internal pure {
        for (uint256 i = 1; i < keys.length; i++) {
            uint256 key = keys[i];
            address addr = vm.addr(key);
            uint256 j = i;
            while (j > 0 && vm.addr(keys[j - 1]) > addr) {
                keys[j] = keys[j - 1];
                j--;
            }
            keys[j] = key;
        }
    }

    function _sortTwoKeys(uint256 k1, uint256 k2) internal pure returns (uint256, uint256) {
        if (vm.addr(k1) < vm.addr(k2)) return (k1, k2);
        return (k2, k1);
    }

    /// @dev Sort 5 addresses ascending. Simple insertion sort.
    function _sortAddresses(
        address a, address b, address c, address d, address e
    ) internal pure returns (address[] memory) {
        address[] memory arr = new address[](5);
        arr[0] = a; arr[1] = b; arr[2] = c; arr[3] = d; arr[4] = e;
        for (uint256 i = 1; i < arr.length; i++) {
            address val = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > val) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = val;
        }
        return arr;
    }

    function _sortAddresses3(
        address a, address b, address c
    ) internal pure returns (address[] memory) {
        address[] memory arr = new address[](3);
        arr[0] = a; arr[1] = b; arr[2] = c;
        for (uint256 i = 1; i < arr.length; i++) {
            address val = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > val) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = val;
        }
        return arr;
    }
}
