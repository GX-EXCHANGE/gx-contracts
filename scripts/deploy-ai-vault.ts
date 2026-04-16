import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXAIVault with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Addresses ──
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";
  const DEPLOYER_ADDRESS = "0x7856895b26b3E8Bc6ACc82119fBAC370f41FBa6F";

  // ── Vault parameters ──
  const VAULT_NAME = "GX AI Vault";
  const VAULT_SYMBOL = "gxAI";
  const DEPOSIT_CAP = ethers.parseUnits("10000000", 6); // 10M USDC (6 decimals)
  const STRATEGY_MANAGER = DEPLOYER_ADDRESS; // Deployer manages strategy initially

  // ── Deploy GXAIVault ──
  console.log("\n--- Deploying GXAIVault ---");
  console.log("  Asset (USDC):", USDC);
  console.log("  Name:", VAULT_NAME);
  console.log("  Symbol:", VAULT_SYMBOL);
  console.log("  Treasury:", TREASURY);
  console.log("  Deposit cap:", "10,000,000 USDC");
  console.log("  Strategy manager:", STRATEGY_MANAGER);
  console.log("  Owner:", DEPLOYER_ADDRESS);

  const GXAIVault = await ethers.getContractFactory("GXAIVault");
  const vault = await GXAIVault.deploy(
    USDC,
    VAULT_NAME,
    VAULT_SYMBOL,
    TREASURY,
    DEPOSIT_CAP,
    STRATEGY_MANAGER,
    DEPLOYER_ADDRESS
  );
  await vault.waitForDeployment();

  const address = await vault.getAddress();
  const txHash = vault.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXAIVault DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", address);
  console.log("Transaction hash:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${address}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify on Arbiscan ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for 5 block confirmations...");
    await vault.deploymentTransaction()!.wait(5);

    console.log("Verifying contract on Arbiscan...");
    try {
      await run("verify:verify", {
        address,
        constructorArguments: [
          USDC,
          VAULT_NAME,
          VAULT_SYMBOL,
          TREASURY,
          DEPOSIT_CAP,
          STRATEGY_MANAGER,
          DEPLOYER_ADDRESS,
        ],
      });
      console.log("Contract verified!");
    } catch (error: any) {
      console.warn("Verification failed (non-fatal):", error.message);
    }
  }

  // ── Save deployment info ──
  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const deploymentInfo = {
    contract: "GXAIVault",
    name: VAULT_NAME,
    symbol: VAULT_SYMBOL,
    address,
    txHash,
    deployer: deployer.address,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${address}`,
    constructorArgs: {
      asset: USDC,
      name: VAULT_NAME,
      symbol: VAULT_SYMBOL,
      treasury: TREASURY,
      depositCap: DEPOSIT_CAP.toString(),
      strategyManager: STRATEGY_MANAGER,
      owner: DEPLOYER_ADDRESS,
    },
  };

  const outPath = path.join(deploymentsDir, "gx-ai-vault.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  NEXT: Transfer strategy manager role if needed");
  console.log("  NEXT: Approve USDC deposits to vault");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
