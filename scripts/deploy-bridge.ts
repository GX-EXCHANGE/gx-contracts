import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXBridge");
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH");

  // ── Addresses ──
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const USDT = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";
  const GX_TOKEN = "0xA57744C4b421c392eBFeC4fe3332669FEF3Cbf5F";

  // Bridge ID
  const bridgeId = ethers.keccak256(ethers.toUtf8Bytes("gx-bridge-arbitrum-v1"));

  // Initial validator set — deployer as sole validator with full power
  const validators = [deployer.address];
  const powers = [ethers.parseUnits("1", 0) * 4294967296n]; // 2^32 = full power

  // Supported tokens
  const supportedTokens = [USDC, USDT, GX_TOKEN];

  // Daily withdrawal limit: $1M USDC equivalent (6 decimals)
  const dailyWithdrawalLimit = ethers.parseUnits("1000000", 6);

  console.log("\n--- GXBridge Parameters ---");
  console.log("Bridge ID:", bridgeId);
  console.log("Validators:", validators);
  console.log("Supported tokens: USDC, USDT, GX");
  console.log("Daily limit: $1,000,000");

  // ── Deploy ──
  console.log("\n--- Deploying ---");
  const GXBridge = await ethers.getContractFactory("GXBridge");
  const contract = await GXBridge.deploy(
    bridgeId,
    validators,
    powers,
    supportedTokens,
    dailyWithdrawalLimit
  );
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  const txHash = contract.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXBridge DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract:", address);
  console.log("Tx:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${address}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for confirmations...");
    await contract.deploymentTransaction()!.wait(5);

    console.log("Verifying on Arbiscan...");
    try {
      await run("verify:verify", {
        address,
        constructorArguments: [bridgeId, validators, powers, supportedTokens, dailyWithdrawalLimit],
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
    path.join(deploymentsDir, "gx-bridge.json"),
    JSON.stringify({
      contract: "GXBridge",
      address,
      txHash,
      deployer: deployer.address,
      network: network.name,
      chainId: (await ethers.provider.getNetwork()).chainId.toString(),
      deployedAt: new Date().toISOString(),
      arbiscan: `https://arbiscan.io/address/${address}`,
      args: { bridgeId, validators, supportedTokens: ["USDC", "USDT", "GX"], dailyLimit: "$1M" },
    }, null, 2)
  );

  console.log("\nDeploy complete.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
