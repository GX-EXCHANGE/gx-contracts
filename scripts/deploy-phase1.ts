import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying Phase 1 contracts with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Known addresses ──
  const GX_TOKEN = "0xA57744C4b421c392eBFeC4fe3332669FEF3Cbf5F";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";

  // ══════════════════════════════════════════════════════════════════════
  //  Deploy GXSignalSubscription
  // ══════════════════════════════════════════════════════════════════════

  console.log("\n--- Deploying GXSignalSubscription ---");
  const GXSignalSubscription = await ethers.getContractFactory("GXSignalSubscription");
  const signal = await GXSignalSubscription.deploy(GX_TOKEN);
  await signal.waitForDeployment();

  const signalAddress = await signal.getAddress();
  const signalTxHash = signal.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXSignalSubscription DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", signalAddress);
  console.log("Transaction hash:", signalTxHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${signalAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ══════════════════════════════════════════════════════════════════════
  //  Deploy GXBotSubscription
  // ══════════════════════════════════════════════════════════════════════

  console.log("\n--- Deploying GXBotSubscription ---");
  const GXBotSubscription = await ethers.getContractFactory("GXBotSubscription");
  const bot = await GXBotSubscription.deploy(GX_TOKEN, TREASURY);
  await bot.waitForDeployment();

  const botAddress = await bot.getAddress();
  const botTxHash = bot.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXBotSubscription DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", botAddress);
  console.log("Transaction hash:", botTxHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${botAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify on Arbiscan ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await signal.deploymentTransaction()!.wait(5);
    await bot.deploymentTransaction()!.wait(5);

    console.log("Verifying GXSignalSubscription on Arbiscan...");
    try {
      await run("verify:verify", {
        address: signalAddress,
        constructorArguments: [GX_TOKEN],
      });
      console.log("GXSignalSubscription verified!");
    } catch (error: any) {
      console.warn("Verification failed (non-fatal):", error.message);
    }

    console.log("Verifying GXBotSubscription on Arbiscan...");
    try {
      await run("verify:verify", {
        address: botAddress,
        constructorArguments: [GX_TOKEN, TREASURY],
      });
      console.log("GXBotSubscription verified!");
    } catch (error: any) {
      console.warn("Verification failed (non-fatal):", error.message);
    }
  }

  // ── Save deployment info ──
  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const signalDeployment = {
    contract: "GXSignalSubscription",
    address: signalAddress,
    txHash: signalTxHash,
    deployer: deployer.address,
    gxToken: GX_TOKEN,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscanAddress: `https://arbiscan.io/address/${signalAddress}`,
    arbiscanTx: `https://arbiscan.io/tx/${signalTxHash}`,
  };

  const signalOutPath = path.join(deploymentsDir, "gx-signal-subscription.json");
  fs.writeFileSync(signalOutPath, JSON.stringify(signalDeployment, null, 2));
  console.log("\nSignal deployment info saved to:", signalOutPath);

  const botDeployment = {
    contract: "GXBotSubscription",
    address: botAddress,
    txHash: botTxHash,
    deployer: deployer.address,
    gxToken: GX_TOKEN,
    treasury: TREASURY,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscanAddress: `https://arbiscan.io/address/${botAddress}`,
    arbiscanTx: `https://arbiscan.io/tx/${botTxHash}`,
  };

  const botOutPath = path.join(deploymentsDir, "gx-bot-subscription.json");
  fs.writeFileSync(botOutPath, JSON.stringify(botDeployment, null, 2));
  console.log("Bot deployment info saved to:", botOutPath);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  PHASE 1 COMPLETE");
  console.log("═══════════════════════════════════════════════════");
  console.log("GXSignalSubscription:", signalAddress);
  console.log("GXBotSubscription:   ", botAddress);
  console.log("\n  NEXT STEP: Run deploy-staking.ts");
  console.log("  npx hardhat run scripts/deploy-staking.ts --network arbitrumOne");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
