import { ethers } from "hardhat";

/**
 * Deploy GXVaultV2 to Arbitrum Sepolia testnet.
 *
 * Usage:
 *   ESTIMATE_ONLY=true npx hardhat run scripts/deploy-vault-sepolia.ts --network arbitrumSepolia
 *   npx hardhat run scripts/deploy-vault-sepolia.ts --network arbitrumSepolia
 *
 * Requires DEPLOYER_PRIVATE_KEY in .env (must hold Sepolia ETH for gas).
 */
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXVaultV2 to Arbitrum Sepolia with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — get Sepolia ETH from a faucet");
  }

  // Constructor args — single validator (deployer) for testnet
  const validators = [deployer.address];
  const maxTotalDeposits = 1_000_000_000_000n; // $1,000,000 cap (6 decimals) — generous for testnet

  console.log("\n--- Deployment Parameters ---");
  console.log("Network: Arbitrum Sepolia (chain 421614)");
  console.log("Validators:", validators);
  console.log("Max total deposits:", maxTotalDeposits.toString(), `($${Number(maxTotalDeposits) / 1_000_000} USDC)`);
  console.log("Quorum: >2/3 validator signatures required");
  console.log("Withdrawal delay: 1h standard, 24h for >$100k");

  // Gas estimation
  const GXVaultV2 = await ethers.getContractFactory("GXVaultV2");
  const deployTx = await GXVaultV2.getDeployTransaction(validators, maxTotalDeposits);

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
  console.log("Sufficient:", balance >= estimatedCost ? "YES" : "NO — need more ETH");

  if (process.env.ESTIMATE_ONLY === "true") {
    console.log("\n[ESTIMATE ONLY — not deploying]");
    return;
  }

  // Deploy
  console.log("\n--- Deploying GXVaultV2 ---");
  const vault = await GXVaultV2.deploy(validators, maxTotalDeposits);
  await vault.waitForDeployment();

  const address = await vault.getAddress();
  const txHash = vault.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXVaultV2 DEPLOYED on Arbitrum Sepolia");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", address);
  console.log("Transaction hash:", txHash);
  console.log("Explorer:", `https://sepolia.arbiscan.io/address/${address}`);
  console.log("Tx:", `https://sepolia.arbiscan.io/tx/${txHash}`);
  console.log("═══════════════════════════════════════════════════");

  console.log("\nNext steps:");
  console.log("  1. Verify:  npx hardhat verify --network arbitrumSepolia", address, `'[\"${deployer.address}\"]'`, maxTotalDeposits.toString());
  console.log("  2. Set GX_VAULT_ADDRESS=" + address + " in Gx-Engine .env");
  console.log("  3. Add a test USDC token via vault.addToken(<sepolia-usdc>)");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
