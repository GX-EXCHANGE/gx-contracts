import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXStaking with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Known addresses ──
  const GX_TOKEN = "0xA57744C4b421c392eBFeC4fe3332669FEF3Cbf5F";
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

  // Use deployer for both owner and rewardsDistributor (temporary until FeeDistributor is deployed)
  const owner = deployer.address;
  const rewardsDistributor = deployer.address;

  console.log("\n--- Staking Parameters ---");
  console.log("Owner:", owner);
  console.log("Rewards Distributor:", rewardsDistributor, "(temporary — deployer)");
  console.log("Staking Token:", GX_TOKEN, "(GX)");
  console.log("Reward Token A:", USDC, "(USDC)");
  console.log("Reward Token B:", GX_TOKEN, "(GX)");

  // ══════════════════════════════════════════════════════════════════════
  //  Deploy GXStaking
  // ══════════════════════════════════════════════════════════════════════

  console.log("\n--- Deploying GXStaking ---");
  const GXStaking = await ethers.getContractFactory("GXStaking");
  const staking = await GXStaking.deploy(
    owner,
    rewardsDistributor,
    GX_TOKEN,
    USDC,
    GX_TOKEN
  );
  await staking.waitForDeployment();

  const stakingAddress = await staking.getAddress();
  const txHash = staking.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXStaking DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", stakingAddress);
  console.log("Transaction hash:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${stakingAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify on Arbiscan ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await staking.deploymentTransaction()!.wait(5);

    console.log("Verifying GXStaking on Arbiscan...");
    try {
      await run("verify:verify", {
        address: stakingAddress,
        constructorArguments: [
          owner,
          rewardsDistributor,
          GX_TOKEN,
          USDC,
          GX_TOKEN,
        ],
      });
      console.log("GXStaking verified!");
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
    contract: "GXStaking",
    address: stakingAddress,
    txHash,
    deployer: deployer.address,
    owner,
    rewardsDistributor,
    rewardsDistributorNote: "Temporary — deployer until FeeDistributor is deployed",
    stakingToken: GX_TOKEN,
    rewardTokenA: USDC,
    rewardTokenB: GX_TOKEN,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscanAddress: `https://arbiscan.io/address/${stakingAddress}`,
    arbiscanTx: `https://arbiscan.io/tx/${txHash}`,
  };

  const outPath = path.join(deploymentsDir, "gx-staking.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  NEXT STEP: Run deploy-governance.ts");
  console.log("  npx hardhat run scripts/deploy-governance.ts --network arbitrumOne");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
