import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  // Read token address from previous deployment
  const tokenDeploymentPath = path.join(__dirname, "deployments", "gx-token.json");
  if (!fs.existsSync(tokenDeploymentPath)) {
    throw new Error(
      `Token deployment not found at ${tokenDeploymentPath}. Deploy GXToken first with deploy-token.ts`
    );
  }

  const tokenDeployment = JSON.parse(fs.readFileSync(tokenDeploymentPath, "utf-8"));
  const tokenAddress = tokenDeployment.address;
  console.log("Using GXToken at:", tokenAddress);

  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXVesting with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas");
  }

  // Vesting parameters
  const founderWallet = process.env.FOUNDER_WALLET;
  if (!founderWallet) {
    throw new Error("Missing FOUNDER_WALLET in .env");
  }
  const beneficiary = founderWallet; // Founder wallet (separate from deployer)
  const totalAllocation = ethers.parseUnits("50000000", 18); // 50M GX (18 decimals)
  const cliffDuration = 365 * 24 * 60 * 60; // 1 year in seconds
  const vestingDuration = 1095 * 24 * 60 * 60; // 3 years in seconds (includes cliff)

  console.log("\n--- Vesting Parameters ---");
  console.log("Beneficiary:", beneficiary);
  console.log("Total allocation: 50,000,000 GX");
  console.log("Cliff: 365 days (1 year)");
  console.log("Total vesting: 1,095 days (3 years)");

  // Deploy GXVesting
  console.log("\n--- Deploying GXVesting ---");
  const GXVesting = await ethers.getContractFactory("GXVesting");
  const vesting = await GXVesting.deploy(
    beneficiary,
    tokenAddress,
    totalAllocation,
    cliffDuration,
    vestingDuration
  );
  await vesting.waitForDeployment();

  const vestingAddress = await vesting.getAddress();
  const txHash = vesting.deploymentTransaction()?.hash;

  // Transfer 50M GX tokens to the vesting contract
  console.log("\n--- Transferring 50,000,000 GX to vesting contract ---");
  const token = await ethers.getContractAt("GXToken", tokenAddress);
  const transferTx = await token.transfer(vestingAddress, totalAllocation);
  await transferTx.wait();
  console.log("Transfer complete. Tx:", transferTx.hash);

  // Calculate schedule dates
  const block = await ethers.provider.getBlock("latest");
  const deployTimestamp = block!.timestamp;
  const cliffEndDate = new Date(deployTimestamp * 1000 + cliffDuration * 1000);
  const vestingEndDate = new Date(deployTimestamp * 1000 + vestingDuration * 1000);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXVesting DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Vesting contract:", vestingAddress);
  console.log("Transaction hash:", txHash);
  console.log("Token locked: 50,000,000 GX");
  console.log("Cliff ends:", cliffEndDate.toISOString());
  console.log("Vesting ends:", vestingEndDate.toISOString());
  console.log("Arbiscan:", `https://arbiscan.io/address/${vestingAddress}`);
  console.log("Tx:", `https://arbiscan.io/tx/${txHash}`);
  console.log("═══════════════════════════════════════════════════");

  // Verify on Arbiscan if not on a local network
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await vesting.deploymentTransaction()!.wait(5);

    console.log("Verifying contract on Arbiscan...");
    try {
      await run("verify:verify", {
        address: vestingAddress,
        constructorArguments: [
          beneficiary,
          tokenAddress,
          totalAllocation,
          cliffDuration,
          vestingDuration,
        ],
      });
      console.log("Contract verified!");
    } catch (error: any) {
      console.warn("Verification failed (non-fatal):", error.message);
    }
  }

  // Save deployment info
  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const deploymentInfo = {
    contract: "GXVesting",
    address: vestingAddress,
    txHash,
    transferTxHash: transferTx.hash,
    deployer: deployer.address,
    beneficiary,
    tokenAddress,
    totalAllocation: "50000000000000000000000000",
    totalAllocationHuman: "50,000,000 GX",
    cliffDuration: cliffDuration.toString(),
    vestingDuration: vestingDuration.toString(),
    cliffEndDate: cliffEndDate.toISOString(),
    vestingEndDate: vestingEndDate.toISOString(),
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscanAddress: `https://arbiscan.io/address/${vestingAddress}`,
    arbiscanTx: `https://arbiscan.io/tx/${txHash}`,
  };

  const outPath = path.join(deploymentsDir, "gx-vesting.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
