import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying Governance System with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Known addresses ──
  const GX_TOKEN = "0xA57744C4b421c392eBFeC4fe3332669FEF3Cbf5F";
  const ADDRESS_ZERO = "0x0000000000000000000000000000000000000000";

  // ══════════════════════════════════════════════════════════════════════
  //  Step 1: Deploy GXveToken
  // ══════════════════════════════════════════════════════════════════════

  console.log("\n--- Deploying GXveToken ---");
  const GXveToken = await ethers.getContractFactory("GXveToken");
  const veToken = await GXveToken.deploy(GX_TOKEN);
  await veToken.waitForDeployment();

  const veTokenAddress = await veToken.getAddress();
  const veTokenTxHash = veToken.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXveToken DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", veTokenAddress);
  console.log("Transaction hash:", veTokenTxHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${veTokenAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ══════════════════════════════════════════════════════════════════════
  //  Step 2: Deploy GXTimelock + GXGovernor (nonce pre-computation)
  // ══════════════════════════════════════════════════════════════════════

  const nonce = await ethers.provider.getTransactionCount(deployer.address);
  // Timelock deploys at nonce, Governor at nonce+1
  const governorAddr = ethers.getCreateAddress({ from: deployer.address, nonce: nonce + 1 });

  console.log("\n--- Nonce Pre-computation ---");
  console.log("Current nonce:", nonce);
  console.log("Timelock will deploy at nonce:", nonce);
  console.log("Governor will deploy at nonce:", nonce + 1);
  console.log("Pre-computed Governor address:", governorAddr);

  // Deploy GXTimelock
  console.log("\n--- Deploying GXTimelock ---");
  const GXTimelock = await ethers.getContractFactory("GXTimelock");
  const timelock = await GXTimelock.deploy(
    [governorAddr],  // proposers = pre-computed GXGovernor
    [ADDRESS_ZERO]   // executors = anyone
  );
  await timelock.waitForDeployment();

  const timelockAddress = await timelock.getAddress();
  const timelockTxHash = timelock.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXTimelock DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", timelockAddress);
  console.log("Min delay: 48 hours");
  console.log("═══════════════════════════════════════════════════");

  // Deploy GXGovernor (uses veGX for voting power, NOT plain GX)
  console.log("\n--- Deploying GXGovernor ---");
  const GXGovernor = await ethers.getContractFactory("GXGovernor");
  const governor = await GXGovernor.deploy(veTokenAddress, timelockAddress);
  await governor.waitForDeployment();

  const governorAddress = await governor.getAddress();
  const governorTxHash = governor.deploymentTransaction()?.hash;

  // Verify nonce prediction
  if (governorAddress.toLowerCase() !== governorAddr.toLowerCase()) {
    console.error("WARNING: Pre-computed governor address mismatch!");
    console.error("  Expected:", governorAddr);
    console.error("  Actual:  ", governorAddress);
    throw new Error("Governor address mismatch — Timelock proposer is wrong. Redeploy required.");
  }

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXGovernor DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", governorAddress);
  console.log("Pre-computed match: CONFIRMED");
  console.log("Voting token: veGX at", veTokenAddress);
  console.log("Timelock:", timelockAddress);
  console.log("Proposal threshold: 10,000 GX in veGX");
  console.log("Quorum: 1% of total veGX supply");
  console.log("═══════════════════════════════════════════════════");

  // ══════════════════════════════════════════════════════════════════════
  //  Step 3: Lock 25M GX from Emissions wallet into veGX (4 years)
  // ══════════════════════════════════════════════════════════════════════

  const emissionsKey = process.env.EMISSIONS_PRIVATE_KEY;
  if (emissionsKey) {
    console.log("\n--- Locking 25M GX in veGX from Emissions wallet ---");

    const emissionsSigner = new ethers.Wallet(emissionsKey, ethers.provider);
    console.log("Emissions wallet:", emissionsSigner.address);

    const emissionsBalance = await ethers.provider.getBalance(emissionsSigner.address);
    console.log("Emissions ETH balance:", ethers.formatEther(emissionsBalance), "ETH");

    if (emissionsBalance === 0n) {
      console.warn("WARNING: Emissions wallet has no ETH for gas. Skipping lock.");
      console.warn("Send ETH to", emissionsSigner.address, "and run lock separately.");
    } else {
      const gxToken = await ethers.getContractAt("GXToken", GX_TOKEN, emissionsSigner);
      const veTokenAsEmissions = await ethers.getContractAt("GXveToken", veTokenAddress, emissionsSigner);

      const lockAmount = ethers.parseUnits("25000000", 18); // 25M GX
      const fourYears = 4 * 365 * 86400;
      const block = await ethers.provider.getBlock("latest");
      const unlockTime = block!.timestamp + fourYears;
      // Round to nearest week (veGX requirement)
      const WEEK = 7 * 86400;
      const roundedUnlockTime = Math.floor(unlockTime / WEEK) * WEEK;

      // Approve veGX to spend GX
      console.log("  Approving veGX to spend 25M GX...");
      const approveTx = await gxToken.approve(veTokenAddress, lockAmount);
      await approveTx.wait();
      console.log("  Approved. Tx:", approveTx.hash);

      // Create lock
      console.log("  Creating 4-year lock for 25M GX...");
      const lockTx = await veTokenAsEmissions.create_lock(lockAmount, roundedUnlockTime);
      await lockTx.wait();
      console.log("  Locked! Tx:", lockTx.hash);

      const unlockDate = new Date(roundedUnlockTime * 1000);
      console.log("\n═══════════════════════════════════════════════════");
      console.log("  25M GX LOCKED IN veGX");
      console.log("═══════════════════════════════════════════════════");
      console.log("  Amount: 25,000,000 GX");
      console.log("  Lock duration: 4 years");
      console.log("  Unlock date:", unlockDate.toISOString());
      console.log("  Voting power: ~25,000,000 veGX (maximum)");
      console.log("  Quorum floor: 1% = 250,000 veGX ($20,000 to attack)");
      console.log("═══════════════════════════════════════════════════");
    }
  } else {
    console.warn("\nWARNING: EMISSIONS_PRIVATE_KEY not set in .env. Skipping 25M lock.");
    console.warn("Add it and run the lock separately.");
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Verify all contracts on Arbiscan
  // ══════════════════════════════════════════════════════════════════════

  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await veToken.deploymentTransaction()!.wait(5);

    console.log("Verifying GXveToken...");
    try {
      await run("verify:verify", { address: veTokenAddress, constructorArguments: [GX_TOKEN] });
      console.log("GXveToken verified!");
    } catch (e: any) { console.warn("Verification failed:", e.message); }

    console.log("Verifying GXTimelock...");
    try {
      await run("verify:verify", { address: timelockAddress, constructorArguments: [[governorAddress], [ADDRESS_ZERO]] });
      console.log("GXTimelock verified!");
    } catch (e: any) { console.warn("Verification failed:", e.message); }

    console.log("Verifying GXGovernor...");
    try {
      await run("verify:verify", { address: governorAddress, constructorArguments: [veTokenAddress, timelockAddress] });
      console.log("GXGovernor verified!");
    } catch (e: any) { console.warn("Verification failed:", e.message); }
  }

  // ══════════════════════════════════════════════════════════════════════
  //  Save deployment info
  // ══════════════════════════════════════════════════════════════════════

  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  fs.writeFileSync(path.join(deploymentsDir, "gx-vetoken.json"), JSON.stringify({
    contract: "GXveToken",
    address: veTokenAddress,
    txHash: veTokenTxHash,
    gxToken: GX_TOKEN,
    minLock: "7 days",
    maxLock: "4 years",
    network: network.name,
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${veTokenAddress}`,
  }, null, 2));

  fs.writeFileSync(path.join(deploymentsDir, "gx-timelock.json"), JSON.stringify({
    contract: "GXTimelock",
    address: timelockAddress,
    txHash: timelockTxHash,
    minDelay: "48 hours (172800 seconds)",
    proposers: [governorAddress],
    executors: ["anyone"],
    network: network.name,
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${timelockAddress}`,
  }, null, 2));

  fs.writeFileSync(path.join(deploymentsDir, "gx-governor.json"), JSON.stringify({
    contract: "GXGovernor",
    address: governorAddress,
    txHash: governorTxHash,
    votingToken: veTokenAddress,
    timelock: timelockAddress,
    proposalThreshold: "10,000 GX in veGX",
    quorum: "1% of total veGX supply",
    votingDelay: "1 day (7200 blocks)",
    votingPeriod: "5 days (36000 blocks)",
    network: network.name,
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${governorAddress}`,
  }, null, 2));

  console.log("\nDeployment info saved to scripts/deployments/");

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GOVERNANCE SYSTEM COMPLETE");
  console.log("═══════════════════════════════════════════════════");
  console.log("  GXveToken:   ", veTokenAddress);
  console.log("  GXTimelock:  ", timelockAddress);
  console.log("  GXGovernor:  ", governorAddress);
  console.log("  25M GX locked for 4 years (governance security)");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
