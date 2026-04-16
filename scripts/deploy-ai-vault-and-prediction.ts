import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXAIVault + GXPredictionV3");
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH\n");

  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";

  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  // ════════════════════════════════════════════════════════════════
  //  1. GXAIVault (ERC-4626)
  // ════════════════════════════════════════════════════════════════

  console.log("--- Deploying GXAIVault ---");
  const depositCap = ethers.parseUnits("10000000", 6); // $10M cap

  const GXAIVault = await ethers.getContractFactory("GXAIVault");
  const vault = await GXAIVault.deploy(
    USDC,
    "GX AI Vault",
    "gxUSDC",
    TREASURY,
    depositCap,
    deployer.address, // strategyManager (AI trader address, update later)
    deployer.address  // owner
  );
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  const vaultTx = vault.deploymentTransaction()?.hash;

  console.log("GXAIVault:", vaultAddr);
  console.log("Tx:", vaultTx);

  // ════════════════════════════════════════════════════════════════
  //  2. GXPredictionV3 (Polymarket-style)
  // ════════════════════════════════════════════════════════════════

  console.log("\n--- Deploying GXPredictionV3 ---");

  const GXPredictionV3 = await ethers.getContractFactory("GXPredictionV3");
  const prediction = await GXPredictionV3.deploy(
    USDC,              // collateral token
    TREASURY,          // fee recipient
    deployer.address,  // operator (can create markets, settle)
    100                // fee: 1% (100 bps)
  );
  await prediction.waitForDeployment();
  const predAddr = await prediction.getAddress();
  const predTx = prediction.deploymentTransaction()?.hash;

  console.log("GXPredictionV3:", predAddr);
  console.log("Tx:", predTx);

  // ════════════════════════════════════════════════════════════════
  //  Verify both
  // ════════════════════════════════════════════════════════════════

  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for confirmations...");
    await prediction.deploymentTransaction()!.wait(5);

    console.log("Verifying GXAIVault...");
    try {
      await run("verify:verify", {
        address: vaultAddr,
        constructorArguments: [USDC, "GX AI Vault", "gxUSDC", TREASURY, depositCap, deployer.address, deployer.address],
      });
      console.log("GXAIVault verified!");
    } catch (e: any) { console.warn("Verify failed:", e.message); }

    console.log("Verifying GXPredictionV3...");
    try {
      await run("verify:verify", {
        address: predAddr,
        constructorArguments: [USDC, TREASURY, deployer.address, 100],
      });
      console.log("GXPredictionV3 verified!");
    } catch (e: any) { console.warn("Verify failed:", e.message); }
  }

  // ════════════════════════════════════════════════════════════════
  //  Save
  // ════════════════════════════════════════════════════════════════

  fs.writeFileSync(path.join(deploymentsDir, "gx-ai-vault.json"), JSON.stringify({
    contract: "GXAIVault", address: vaultAddr, txHash: vaultTx,
    deployer: deployer.address, network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${vaultAddr}`,
  }, null, 2));

  fs.writeFileSync(path.join(deploymentsDir, "gx-prediction-v3.json"), JSON.stringify({
    contract: "GXPredictionV3", address: predAddr, txHash: predTx,
    deployer: deployer.address, network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${predAddr}`,
  }, null, 2));

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  ALL DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("GXAIVault:       ", vaultAddr);
  console.log("GXPredictionV3:  ", predAddr);
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
