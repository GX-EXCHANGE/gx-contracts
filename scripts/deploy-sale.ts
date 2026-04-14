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
  console.log("Deploying GXTokenSale with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas");
  }

  // Arbitrum mainnet token addresses
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const USDT = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";
  const PRICE_IN_CENTS = 8; // $0.08

  console.log("\n--- Sale Parameters ---");
  console.log("GX Token:", tokenAddress);
  console.log("USDC:", USDC);
  console.log("USDT:", USDT);
  console.log("Price: $0.08 per GX (8 cents)");

  // Deploy GXTokenSale
  console.log("\n--- Deploying GXTokenSale ---");
  const GXTokenSale = await ethers.getContractFactory("GXTokenSale");
  const sale = await GXTokenSale.deploy(tokenAddress, USDC, USDT, PRICE_IN_CENTS);
  await sale.waitForDeployment();

  const saleAddress = await sale.getAddress();
  const txHash = sale.deploymentTransaction()?.hash;

  // Transfer Fair Launch GX to the sale contract (160M)
  const SALE_AMOUNT = ethers.parseUnits("160000000", 18); // 160M GX
  console.log("\n--- Transferring 160,000,000 GX to sale contract ---");
  const token = await ethers.getContractAt("GXToken", tokenAddress);
  const transferTx = await token.transfer(saleAddress, SALE_AMOUNT);
  await transferTx.wait();
  console.log("Transfer complete. Tx:", transferTx.hash);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXTokenSale DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Sale contract:", saleAddress);
  console.log("Transaction hash:", txHash);
  console.log("GX loaded: 160,000,000");
  console.log("Price: $0.08 per GX");
  console.log("Max raise: $12,800,000 (if all sold)");
  console.log("Arbiscan:", `https://arbiscan.io/address/${saleAddress}`);
  console.log("═══════════════════════════════════════════════════");

  // Verify on Arbiscan
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await sale.deploymentTransaction()!.wait(5);

    console.log("Verifying contract on Arbiscan...");
    try {
      await run("verify:verify", {
        address: saleAddress,
        constructorArguments: [tokenAddress, USDC, USDT, PRICE_IN_CENTS],
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
    contract: "GXTokenSale",
    address: saleAddress,
    txHash,
    transferTxHash: transferTx.hash,
    deployer: deployer.address,
    tokenAddress,
    usdc: USDC,
    usdt: USDT,
    priceInCents: PRICE_IN_CENTS,
    priceUsd: "$0.08",
    gxLoaded: "160,000,000",
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${saleAddress}`,
  };

  const outPath = path.join(deploymentsDir, "gx-sale.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);

  // Check deployer remaining balance
  const deployerGx = await token.balanceOf(deployer.address);
  console.log(`\nDeployer remaining: ${ethers.formatUnits(deployerGx, 18)} GX`);
  console.log("(Should be ~100,000 for Auto-Liquidity GIP-2)");

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  SALE IS LIVE - Users can buy at $0.08/GX");
  console.log("  To stop: call toggleSale() on the contract");
  console.log("  To withdraw USDC: call withdrawUSDC(treasury)");
  console.log("  To recover unsold GX: call recoverGx(wallet)");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
