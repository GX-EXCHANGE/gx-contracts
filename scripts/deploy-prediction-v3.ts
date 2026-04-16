import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXPredictionV3 with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas");
  }

  // ── Known addresses ──
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const TREASURY = process.env.FOUNDATION_WALLET || "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";
  const FEE_BPS = 50; // 0.5% split fee

  console.log("\n--- Prediction V3 Parameters ---");
  console.log("USDC:", USDC);
  console.log("Fee Recipient:", TREASURY);
  console.log("Operator:", deployer.address, "(engine hot wallet)");
  console.log("Fee Rate:", FEE_BPS, "bps (0.5%)");

  // ── Deploy ──
  console.log("\n--- Deploying GXPredictionV3 ---");
  const GXPredictionV3 = await ethers.getContractFactory("GXPredictionV3");
  const prediction = await GXPredictionV3.deploy(
    USDC,
    TREASURY,
    deployer.address, // operator = deployer (engine wallet)
    FEE_BPS
  );
  await prediction.waitForDeployment();

  const address = await prediction.getAddress();
  const txHash = prediction.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXPredictionV3 DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", address);
  console.log("Transaction hash:", txHash);
  console.log("Features:");
  console.log("  - ERC-1155 outcome tokens (YES/NO)");
  console.log("  - Split/Merge (Polymarket-style)");
  console.log("  - Engine batch settlement");
  console.log("  - Oracle + emergency resolution");
  console.log("  - 0.5% split fee");
  console.log("Arbiscan:", `https://arbiscan.io/address/${address}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await prediction.deploymentTransaction()!.wait(5);

    console.log("Verifying on Arbiscan...");
    try {
      await run("verify:verify", {
        address,
        constructorArguments: [USDC, TREASURY, deployer.address, FEE_BPS],
      });
      console.log("Contract verified!");
    } catch (error: any) {
      console.warn("Verification failed (non-fatal):", error.message);
    }
  }

  // ── Save deployment ──
  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const deploymentInfo = {
    contract: "GXPredictionV3",
    address,
    txHash,
    deployer: deployer.address,
    usdc: USDC,
    feeRecipient: TREASURY,
    operator: deployer.address,
    feeBps: FEE_BPS,
    features: [
      "ERC-1155 outcome tokens",
      "Split/Merge (Polymarket CTF-style)",
      "Engine batch settlement",
      "Oracle + emergency resolution",
      "INVALID outcome refund",
    ],
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${address}`,
  };

  const outPath = path.join(deploymentsDir, "gx-prediction-v3.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
