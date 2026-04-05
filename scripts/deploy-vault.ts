import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXVault with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas");
  }

  // Constructor args
  const guardians = [deployer.address]; // Single guardian for now
  const requiredSignatures = 1; // 1/1 until more guardians added
  const maxTotalDeposits = 10_000_000_000n; // $10,000 cap (6 decimals)

  console.log("\n--- Deployment Parameters ---");
  console.log("Guardian:", deployer.address);
  console.log("Required signatures:", requiredSignatures);
  console.log("Max total deposits:", maxTotalDeposits.toString(), `($${Number(maxTotalDeposits) / 1_000_000} USD)`);
  console.log("Min deposit: 5,000,000 ($5 USD)");
  console.log("Withdrawal delay: 86400s (24 hours)");
  console.log("Approved tokens:");
  console.log("  USDC: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831");
  console.log("  USDT: 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9");

  // Gas estimation
  const GXVault = await ethers.getContractFactory("GXVault");
  const deployTx = await GXVault.getDeployTransaction(
    guardians,
    requiredSignatures,
    maxTotalDeposits
  );

  const gasEstimate = await ethers.provider.estimateGas({
    ...deployTx,
    from: deployer.address,
  });

  const feeData = await ethers.provider.getFeeData();
  const gasPrice = feeData.gasPrice || 0n;
  const estimatedCost = gasEstimate * gasPrice;

  console.log("\n--- Gas Estimate ---");
  console.log("Estimated gas:", gasEstimate.toString());
  console.log("Gas price:", ethers.formatUnits(gasPrice, "gwei"), "gwei");
  console.log("Estimated cost:", ethers.formatEther(estimatedCost), "ETH");
  console.log("Balance:", ethers.formatEther(balance), "ETH");
  console.log("Sufficient:", balance >= estimatedCost ? "YES" : "NO — need more ETH");

  // Check if --estimate-only flag
  if (process.env.ESTIMATE_ONLY === "true") {
    console.log("\n[ESTIMATE ONLY — not deploying]");
    return;
  }

  // Deploy
  console.log("\n--- Deploying ---");
  const vault = await GXVault.deploy(guardians, requiredSignatures, maxTotalDeposits);
  await vault.waitForDeployment();

  const address = await vault.getAddress();
  const txHash = vault.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXVault DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", address);
  console.log("Transaction hash:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/address/${address}`);
  console.log("Tx:", `https://arbiscan.io/tx/${txHash}`);
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
