import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploy test environment on Arbitrum Sepolia:
 * 1. TestUSDC (we mint unlimited for testing)
 * 2. GXAIVault (ERC-4626, AI strategy testing)
 * 3. GXPredictionV3 (prediction markets, manual settlement)
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== TESTNET DEPLOYMENT ===");
  console.log("Network:", network.name);
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH\n");

  if (balance === 0n) {
    throw new Error("No Sepolia ETH! Get some from https://faucet.quicknode.com/arbitrum/sepolia");
  }

  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  // ══════════════════════════════════════════════════════════════
  //  1. Deploy TestUSDC (simple ERC-20 with public mint)
  // ══════════════════════════════════════════════════════════════

  console.log("--- 1. Deploying TestUSDC ---");

  // Deploy a simple mintable ERC-20 for testing
  const TestUSDC = await ethers.getContractFactory("GXToken"); // Reuse GXToken as test USDC
  // Actually we need a 6-decimal token. Let's deploy inline:
  const testUsdcFactory = new ethers.ContractFactory(
    [
      "constructor()",
      "function mint(address to, uint256 amount) external",
      "function name() view returns (string)",
      "function symbol() view returns (string)",
      "function decimals() view returns (uint8)",
      "function totalSupply() view returns (uint256)",
      "function balanceOf(address) view returns (uint256)",
      "function transfer(address to, uint256 amount) returns (bool)",
      "function approve(address spender, uint256 amount) returns (bool)",
      "function transferFrom(address from, address to, uint256 amount) returns (bool)",
      "function allowance(address owner, address spender) view returns (uint256)",
    ],
    // Simple ERC20 with mint bytecode - use OpenZeppelin
    "0x", // placeholder
    deployer
  );

  // Instead of deploying custom, let's just use the GXToken contract and treat it as test USDC
  // Mint 100M "USDC" to deployer for testing
  console.log("Using GXToken contract pattern for TestUSDC (18 decimals for simplicity)");

  // Actually, let's use a different approach - deploy GXTokenSale pattern but simpler
  // For now, use deployer address as the "USDC" and just track balances in the vault

  // SIMPLER: Deploy GXAIVault with GX Token as the underlying (test with GX instead of USDC)
  // On testnet, we control everything anyway

  // Let's use a pre-existing testnet USDC if available, or deploy a mock
  // Arbitrum Sepolia has a USDC at 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d (Circle testnet)
  const TEST_USDC = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";

  console.log("Using Arbitrum Sepolia USDC:", TEST_USDC);

  // ══════════════════════════════════════════════════════════════
  //  2. Deploy GXAIVault
  // ══════════════════════════════════════════════════════════════

  console.log("\n--- 2. Deploying GXAIVault ---");
  const depositCap = ethers.parseUnits("1000000", 6); // $1M test cap

  const GXAIVault = await ethers.getContractFactory("GXAIVault");
  const vault = await GXAIVault.deploy(
    TEST_USDC,
    "GX AI Vault (Testnet)",
    "tgxUSDC",
    deployer.address, // treasury = deployer for testing
    depositCap,
    deployer.address, // strategyManager = deployer (we simulate AI trades)
    deployer.address  // owner = deployer
  );
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  console.log("GXAIVault:", vaultAddr);

  // ══════════════════════════════════════════════════════════════
  //  3. Deploy GXPredictionV3
  // ══════════════════════════════════════════════════════════════

  console.log("\n--- 3. Deploying GXPredictionV3 ---");

  const GXPredictionV3 = await ethers.getContractFactory("GXPredictionV3");
  const prediction = await GXPredictionV3.deploy(
    TEST_USDC,         // collateral
    deployer.address,  // fee recipient = deployer for testing
    deployer.address,  // operator = deployer (we create markets & settle manually)
    100                // 1% fee
  );
  await prediction.waitForDeployment();
  const predAddr = await prediction.getAddress();
  console.log("GXPredictionV3:", predAddr);

  // ══════════════════════════════════════════════════════════════
  //  Verify
  // ══════════════════════════════════════════════════════════════

  if (network.name === "arbitrumSepolia") {
    console.log("\nWaiting for confirmations...");
    await prediction.deploymentTransaction()!.wait(5);

    console.log("Verifying GXAIVault...");
    try {
      await run("verify:verify", {
        address: vaultAddr,
        constructorArguments: [TEST_USDC, "GX AI Vault (Testnet)", "tgxUSDC", deployer.address, depositCap, deployer.address, deployer.address],
      });
    } catch (e: any) { console.warn("Verify:", e.message); }

    console.log("Verifying GXPredictionV3...");
    try {
      await run("verify:verify", {
        address: predAddr,
        constructorArguments: [TEST_USDC, deployer.address, deployer.address, 100],
      });
    } catch (e: any) { console.warn("Verify:", e.message); }
  }

  // ══════════════════════════════════════════════════════════════
  //  Save
  // ══════════════════════════════════════════════════════════════

  const info = {
    network: network.name,
    chainId: 421614,
    deployer: deployer.address,
    deployedAt: new Date().toISOString(),
    testUSDC: TEST_USDC,
    GXAIVault: vaultAddr,
    GXPredictionV3: predAddr,
    notes: {
      vault: "Strategy manager = deployer. Deposit USDC, simulate trades, test withdrawals.",
      prediction: "Operator = deployer. Create markets, place bets, settle manually (no oracle).",
      testing: "Run for 14 days. Test drawdown breaker, withdrawal timelock, market resolution.",
    },
  };

  fs.writeFileSync(
    path.join(deploymentsDir, "testnet-sepolia.json"),
    JSON.stringify(info, null, 2)
  );

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  TESTNET DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════════════════════");
  console.log("  Test USDC:       ", TEST_USDC);
  console.log("  GXAIVault:       ", vaultAddr);
  console.log("  GXPredictionV3:  ", predAddr);
  console.log("═══════════════════════════════════════════════════");
  console.log("\n  TESTING GUIDE:");
  console.log("  1. Get test USDC from Sepolia faucet");
  console.log("  2. Approve USDC to GXAIVault → deposit → check shares");
  console.log("  3. As strategy manager: deployFunds → returnFunds (simulate AI)");
  console.log("  4. Create prediction market → place bets → settle manually");
  console.log("  5. Test edge cases: drawdown breaker, timelock, all-in bets");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
