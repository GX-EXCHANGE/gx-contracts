import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXPredictionV2 with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Known addresses (Arbitrum One) ──
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

  // Fee recipient — use FeeDistributor or Treasury address.
  // Falls back to deployer if neither is deployed yet.
  const FEE_RECIPIENT = deployer.address; // TODO: replace with GXFeeDistributor or Treasury

  // 100 USDC creation deposit (6 decimals)
  const CREATION_DEPOSIT = 100_000_000n; // 100e6

  console.log("\n--- PredictionV2 Parameters ---");
  console.log("USDC:             ", USDC);
  console.log("Fee Recipient:    ", FEE_RECIPIENT);
  console.log("Creation Deposit: ", CREATION_DEPOSIT.toString(), "(100 USDC)");

  // ══════════════════════════════════════════════════════════════════════
  //  Deploy GXPredictionV2
  // ══════════════════════════════════════════════════════════════════════

  console.log("\n--- Deploying GXPredictionV2 ---");
  const GXPredictionV2 = await ethers.getContractFactory("GXPredictionV2");
  const prediction = await GXPredictionV2.deploy(
    USDC,
    FEE_RECIPIENT,
    CREATION_DEPOSIT
  );
  await prediction.waitForDeployment();

  const predictionAddress = await prediction.getAddress();
  const txHash = prediction.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXPredictionV2 DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", predictionAddress);
  console.log("Transaction hash:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${predictionAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify on Arbiscan ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await prediction.deploymentTransaction()!.wait(5);

    console.log("Verifying GXPredictionV2 on Arbiscan...");
    try {
      await run("verify:verify", {
        address: predictionAddress,
        constructorArguments: [
          USDC,
          FEE_RECIPIENT,
          CREATION_DEPOSIT,
        ],
      });
      console.log("GXPredictionV2 verified!");
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
    contract: "GXPredictionV2",
    address: predictionAddress,
    txHash,
    deployer: deployer.address,
    usdc: USDC,
    feeRecipient: FEE_RECIPIENT,
    creationDeposit: CREATION_DEPOSIT.toString(),
    splitFeeBps: 100,
    emergencyDelay: "30 days",
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscanAddress: `https://arbiscan.io/address/${predictionAddress}`,
    arbiscanTx: `https://arbiscan.io/tx/${txHash}`,
    notes: "ERC-1155 outcome tokens, split/merge mechanism, oracle + emergency resolution",
  };

  const outPath = path.join(deploymentsDir, "gx-prediction-v2.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  DEPLOYMENT COMPLETE");
  console.log("  Contract: GXPredictionV2");
  console.log("  Features: ERC-1155 outcome tokens, split/merge, oracle resolution");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
