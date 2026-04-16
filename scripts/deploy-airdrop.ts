import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXAirdrop with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Addresses ──
  const GX_TOKEN = "0xA57744C4b421c392eBFeC4fe3332669FEF3Cbf5F";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";

  // ── Airdrop parameters ──
  // Placeholder merkle root — replace with real root before mainnet deploy
  const MERKLE_ROOT = ethers.ZeroHash; // bytes32(0)

  console.log("\n--- Deploying GXAirdrop ---");
  console.log("  Token (GX):", GX_TOKEN);
  console.log("  Merkle root:", MERKLE_ROOT, "(placeholder — update before funding)");
  console.log("  Treasury:", TREASURY);
  console.log("  Claim deadline: 90 days from deployment (set in constructor)");

  // ── Deploy GXAirdrop ──
  const GXAirdrop = await ethers.getContractFactory("GXAirdrop");
  const airdrop = await GXAirdrop.deploy(
    GX_TOKEN,
    MERKLE_ROOT,
    TREASURY
  );
  await airdrop.waitForDeployment();

  const address = await airdrop.getAddress();
  const txHash = airdrop.deploymentTransaction()?.hash;

  // Read the deadline from the deployed contract
  const claimDeadline = await airdrop.claimDeadline();
  const deadlineDate = new Date(Number(claimDeadline) * 1000).toISOString();

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXAirdrop DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", address);
  console.log("Transaction hash:", txHash);
  console.log("Claim deadline:", deadlineDate);
  console.log("Arbiscan:", `https://arbiscan.io/address/${address}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify on Arbiscan ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for 5 block confirmations...");
    await airdrop.deploymentTransaction()!.wait(5);

    console.log("Verifying contract on Arbiscan...");
    try {
      await run("verify:verify", {
        address,
        constructorArguments: [GX_TOKEN, MERKLE_ROOT, TREASURY],
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
    contract: "GXAirdrop",
    address,
    txHash,
    deployer: deployer.address,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${address}`,
    claimDeadline: deadlineDate,
    constructorArgs: {
      token: GX_TOKEN,
      merkleRoot: MERKLE_ROOT,
      treasury: TREASURY,
    },
    notes: "Merkle root is placeholder (bytes32 zero). Redeploy with real merkle root before funding with GX tokens.",
  };

  const outPath = path.join(deploymentsDir, "gx-airdrop.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  IMPORTANT: This was deployed with a PLACEHOLDER merkle root.");
  console.log("  Before going live:");
  console.log("  1. Generate real merkle tree from airdrop allocations");
  console.log("  2. Redeploy with the real merkle root");
  console.log("  3. Transfer GX tokens to the airdrop contract");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
