import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXNodeSubscription with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Known addresses ──
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const USDT = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";

  console.log("\n--- Node Subscription Parameters ---");
  console.log("USDC:", USDC);
  console.log("USDT:", USDT);
  console.log("Treasury:", TREASURY);

  // ══════════════════════════════════════════════════════════════════════
  //  Deploy GXNodeSubscription
  // ══════════════════════════════════════════════════════════════════════

  console.log("\n--- Deploying GXNodeSubscription ---");
  const GXNodeSubscription = await ethers.getContractFactory("GXNodeSubscription");
  const subscription = await GXNodeSubscription.deploy(USDC, USDT, TREASURY);
  await subscription.waitForDeployment();

  const contractAddress = await subscription.getAddress();
  const txHash = subscription.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXNodeSubscription DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", contractAddress);
  console.log("Transaction hash:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${contractAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Verify on Arbiscan ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await subscription.deploymentTransaction()!.wait(5);

    console.log("Verifying GXNodeSubscription on Arbiscan...");
    try {
      await run("verify:verify", {
        address: contractAddress,
        constructorArguments: [USDC, USDT, TREASURY],
      });
      console.log("GXNodeSubscription verified!");
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
    contract: "GXNodeSubscription",
    address: contractAddress,
    txHash,
    deployer: deployer.address,
    usdc: USDC,
    usdt: USDT,
    treasury: TREASURY,
    plans: [
      { id: 0, name: "Starter", monthly: "$99", yearly: "$1,069" },
      { id: 1, name: "Basic", monthly: "$199", yearly: "$2,149" },
      { id: 2, name: "Pro", monthly: "$299", yearly: "$3,229" },
      { id: 3, name: "Business", monthly: "$599", yearly: "$6,469" },
      { id: 4, name: "Enterprise", monthly: "$999", yearly: "$10,789" },
    ],
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscanAddress: `https://arbiscan.io/address/${contractAddress}`,
    arbiscanTx: `https://arbiscan.io/tx/${txHash}`,
  };

  const outPath = path.join(deploymentsDir, "gx-node-subscription.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  DEPLOY COMPLETE");
  console.log("  npx hardhat run scripts/deploy-node-subscription.ts --network arbitrumOne");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
