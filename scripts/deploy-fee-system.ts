import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GX Fee System (GXInsurance + GXFeeDistributor)");
  console.log("Deployer account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Addresses ──
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const GX_STAKING = "0x8e06c52025b588759F0da8882bd2b087e1616517";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";

  // Placeholder addresses for contracts not yet deployed — use treasury as stand-in
  const GX_BRIDGE = TREASURY;   // Replace when GXBridge is deployed
  const GX_USD = TREASURY;      // Replace when GXUSD is deployed
  const GX_LENDING = TREASURY;  // Replace when GXLending is deployed

  // ── Insurance parameters ──
  const MAX_FUND_SIZE = ethers.parseUnits("50000000", 6); // 50M USDC (6 decimals)

  // ════════════════════════════════════════════════════════════════════════════
  //  STEP 1: Deploy GXInsurance
  // ════════════════════════════════════════════════════════════════════════════

  console.log("\n--- Step 1: Deploying GXInsurance ---");
  console.log("  USDC:", USDC);
  console.log("  Max fund size: 50,000,000 USDC");
  console.log("  Treasury:", TREASURY);
  console.log("  GXBridge:", GX_BRIDGE, "(placeholder — treasury)");
  console.log("  GXUSD:", GX_USD, "(placeholder — treasury)");
  console.log("  GXLending:", GX_LENDING, "(placeholder — treasury)");

  const GXInsurance = await ethers.getContractFactory("GXInsurance");
  const insurance = await GXInsurance.deploy(
    USDC,
    MAX_FUND_SIZE,
    TREASURY,
    GX_BRIDGE,
    GX_USD,
    GX_LENDING
  );
  await insurance.waitForDeployment();

  const insuranceAddress = await insurance.getAddress();
  const insuranceTxHash = insurance.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXInsurance DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", insuranceAddress);
  console.log("Transaction hash:", insuranceTxHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${insuranceAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ════════════════════════════════════════════════════════════════════════════
  //  STEP 2: Deploy GXFeeDistributor (uses Insurance address)
  // ════════════════════════════════════════════════════════════════════════════

  console.log("\n--- Step 2: Deploying GXFeeDistributor ---");
  console.log("  Fee token (USDC):", USDC);
  console.log("  Staking contract:", GX_STAKING);
  console.log("  Insurance fund:", insuranceAddress);
  console.log("  Treasury:", TREASURY);

  const GXFeeDistributor = await ethers.getContractFactory("GXFeeDistributor");
  const feeDistributor = await GXFeeDistributor.deploy(
    USDC,
    GX_STAKING,
    insuranceAddress,
    TREASURY
  );
  await feeDistributor.waitForDeployment();

  const feeDistAddress = await feeDistributor.getAddress();
  const feeDistTxHash = feeDistributor.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXFeeDistributor DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", feeDistAddress);
  console.log("Transaction hash:", feeDistTxHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${feeDistAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ════════════════════════════════════════════════════════════════════════════
  //  STEP 3: Verify both contracts on Arbiscan
  // ════════════════════════════════════════════════════════════════════════════

  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for 5 block confirmations...");
    await feeDistributor.deploymentTransaction()!.wait(5);

    // Verify GXInsurance
    console.log("\nVerifying GXInsurance on Arbiscan...");
    try {
      await run("verify:verify", {
        address: insuranceAddress,
        constructorArguments: [
          USDC,
          MAX_FUND_SIZE,
          TREASURY,
          GX_BRIDGE,
          GX_USD,
          GX_LENDING,
        ],
      });
      console.log("GXInsurance verified!");
    } catch (error: any) {
      console.warn("GXInsurance verification failed (non-fatal):", error.message);
    }

    // Verify GXFeeDistributor
    console.log("\nVerifying GXFeeDistributor on Arbiscan...");
    try {
      await run("verify:verify", {
        address: feeDistAddress,
        constructorArguments: [
          USDC,
          GX_STAKING,
          insuranceAddress,
          TREASURY,
        ],
      });
      console.log("GXFeeDistributor verified!");
    } catch (error: any) {
      console.warn("GXFeeDistributor verification failed (non-fatal):", error.message);
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  //  STEP 4: Save deployment info
  // ════════════════════════════════════════════════════════════════════════════

  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  // Save GXInsurance
  const insuranceInfo = {
    contract: "GXInsurance",
    address: insuranceAddress,
    txHash: insuranceTxHash,
    deployer: deployer.address,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${insuranceAddress}`,
    constructorArgs: {
      usdc: USDC,
      maxFundSize: MAX_FUND_SIZE.toString(),
      treasury: TREASURY,
      gxBridge: GX_BRIDGE,
      gxUSD: GX_USD,
      gxLending: GX_LENDING,
    },
    notes: "GXBridge, GXUSD, GXLending set to treasury as placeholder. Immutable — redeploy when those contracts are ready.",
  };

  const insurancePath = path.join(deploymentsDir, "gx-insurance.json");
  fs.writeFileSync(insurancePath, JSON.stringify(insuranceInfo, null, 2));
  console.log("\nGXInsurance deployment saved to:", insurancePath);

  // Save GXFeeDistributor
  const feeDistInfo = {
    contract: "GXFeeDistributor",
    address: feeDistAddress,
    txHash: feeDistTxHash,
    deployer: deployer.address,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${feeDistAddress}`,
    splitRatios: {
      stakers: "40%",
      burn: "20%",
      insurance: "20%",
      treasury: "20%",
    },
    constructorArgs: {
      feeToken: USDC,
      stakingContract: GX_STAKING,
      insuranceFund: insuranceAddress,
      treasury: TREASURY,
    },
  };

  const feeDistPath = path.join(deploymentsDir, "gx-fee-distributor.json");
  fs.writeFileSync(feeDistPath, JSON.stringify(feeDistInfo, null, 2));
  console.log("GXFeeDistributor deployment saved to:", feeDistPath);

  // ── Summary ──
  console.log("\n═══════════════════════════════════════════════════");
  console.log("  FEE SYSTEM DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════════════════════");
  console.log("  GXInsurance:      ", insuranceAddress);
  console.log("  GXFeeDistributor: ", feeDistAddress);
  console.log("═══════════════════════════════════════════════════");
  console.log("\n  NEXT STEPS:");
  console.log("  1. Send USDC fees to the GXFeeDistributor contract");
  console.log("  2. Call distribute() weekly to split fees");
  console.log("  3. Redeploy GXInsurance with real GXBridge/GXUSD/GXLending when ready");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
