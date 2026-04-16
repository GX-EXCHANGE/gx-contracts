import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXFeeDistributor");
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas");
  }

  // ── Addresses ──
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const GX_STAKING = "0x8e06c52025b588759F0da8882bd2b087e1616517";
  const BURN_RESERVE = "0xfFa49362f3668aB3f23431641441932be20C62c7";
  const INSURANCE_FUND = "0xA9EB8eb6A9F31BA470d84451B732A79A124bFb13";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";

  console.log("\n--- GXFeeDistributor Parameters ---");
  console.log("Fee token (USDC):", USDC);
  console.log("Staking (40%):", GX_STAKING);
  console.log("Burn Reserve (20%):", BURN_RESERVE);
  console.log("Insurance Fund (20%):", INSURANCE_FUND);
  console.log("Treasury (20%):", TREASURY);

  // ── Deploy ──
  console.log("\n--- Deploying ---");
  const GXFeeDistributor = await ethers.getContractFactory("GXFeeDistributor");
  const contract = await GXFeeDistributor.deploy(
    USDC,
    GX_STAKING,
    BURN_RESERVE,
    INSURANCE_FUND,
    TREASURY
  );
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  const txHash = contract.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXFeeDistributor DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract:", address);
  console.log("Tx:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${address}`);
  console.log("═══════════════════════════════════════════════════");
  console.log("  40% → GXStaking  ", GX_STAKING);
  console.log("  20% → Burn Reserve", BURN_RESERVE);
  console.log("  20% → Insurance   ", INSURANCE_FUND);
  console.log("  20% → Treasury    ", TREASURY);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for confirmations...");
    await contract.deploymentTransaction()!.wait(5);

    console.log("Verifying on Arbiscan...");
    try {
      await run("verify:verify", {
        address,
        constructorArguments: [USDC, GX_STAKING, BURN_RESERVE, INSURANCE_FUND, TREASURY],
      });
      console.log("Verified!");
    } catch (error: any) {
      console.warn("Verification failed:", error.message);
    }
  }

  // ── Save ──
  const deploymentsDir = path.join(__dirname, "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir, { recursive: true });

  fs.writeFileSync(
    path.join(deploymentsDir, "gx-fee-distributor.json"),
    JSON.stringify({
      contract: "GXFeeDistributor",
      address,
      txHash,
      deployer: deployer.address,
      network: network.name,
      chainId: (await ethers.provider.getNetwork()).chainId.toString(),
      deployedAt: new Date().toISOString(),
      arbiscan: `https://arbiscan.io/address/${address}`,
      split: { stakers: "40%", burnReserve: "20%", insurance: "20%", treasury: "20%" },
      args: { feeToken: USDC, stakingContract: GX_STAKING, burnReserve: BURN_RESERVE, insuranceFund: INSURANCE_FUND, treasury: TREASURY },
    }, null, 2)
  );

  console.log("\nDeploy complete. Next: send USDC fees to", address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
