import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying GXToken with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    throw new Error("Deployer has no ETH for gas — need Arbitrum ETH");
  }

  // ── Read distribution wallets from .env ──
  const FOUNDER_WALLET = process.env.FOUNDER_WALLET;
  const EMISSIONS_WALLET = process.env.EMISSIONS_WALLET;
  const MARKETING_WALLET = process.env.MARKETING_WALLET;
  const AIRDROP_WALLET = process.env.AIRDROP_WALLET;
  const FOUNDATION_WALLET = process.env.FOUNDATION_WALLET;
  const GRANTS_WALLET = process.env.GRANTS_WALLET;

  if (!FOUNDER_WALLET || !EMISSIONS_WALLET || !MARKETING_WALLET || !AIRDROP_WALLET || !FOUNDATION_WALLET || !GRANTS_WALLET) {
    throw new Error("Missing wallet addresses in .env — need all 6 distribution wallets");
  }

  // ── Deploy GXToken ──
  console.log("\n--- Deploying GXToken ---");
  const GXToken = await ethers.getContractFactory("GXToken");
  const token = await GXToken.deploy();
  await token.waitForDeployment();

  const address = await token.getAddress();
  const txHash = token.deploymentTransaction()?.hash;

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  GXToken DEPLOYED");
  console.log("═══════════════════════════════════════════════════");
  console.log("Contract address:", address);
  console.log("Transaction hash:", txHash);
  console.log("Arbiscan:", `https://arbiscan.io/token/${address}`);
  console.log("═══════════════════════════════════════════════════");

  // ── Distribute tokens to allocation wallets ──
  console.log("\n--- Distributing tokens ---");
  const decimals = 18n;
  const toWei = (amount: number) => ethers.parseUnits(amount.toString(), decimals);

  // Token allocation per tokenomics:
  // Total: 1,000,000,000 GX
  // Founder:    50,000,000 (5%)      → held for vesting contract (deploy-vesting.ts)
  // Emissions: 388,900,000 (38.89%)
  // Marketing: 188,000,000 (18.80%)
  // Fair Launch:160,000,000 (16%)    → stays in deployer for spot pair seeding
  // Airdrop:   150,000,000 (15%)
  // Foundation: 60,000,000 (6%)
  // Grants:      3,000,000 (0.30%)
  // AutoLiq:       100,000 (0.01%)   → stays in deployer for GIP-2 order book seeding

  const distributions = [
    // Founder tokens go to deployer first — deploy-vesting.ts will lock them
    // So we DON'T transfer founder allocation here, vesting script handles it
    { name: "Emissions",  wallet: EMISSIONS_WALLET,  amount: 388_900_000 },
    { name: "Marketing",  wallet: MARKETING_WALLET,  amount: 188_000_000 },
    { name: "Airdrop",    wallet: AIRDROP_WALLET,    amount: 150_000_000 },
    { name: "Foundation",  wallet: FOUNDATION_WALLET, amount:  60_000_000 },
    { name: "Grants",     wallet: GRANTS_WALLET,     amount:   3_000_000 },
  ];

  for (const dist of distributions) {
    console.log(`  Sending ${dist.amount.toLocaleString()} GX → ${dist.name} (${dist.wallet})`);
    const tx = await token.transfer(dist.wallet, toWei(dist.amount));
    await tx.wait();
    console.log(`    ✓ Done (tx: ${tx.hash})`);
  }

  // Remaining in deployer:
  // 50,000,000 (Founder — for vesting contract)
  // 160,000,000 (Fair Launch — for spot pair)
  // 100,000 (Auto-Liquidity — for GIP-2)
  const deployerBalance = await token.balanceOf(deployer.address);
  console.log(`\n  Deployer remaining: ${ethers.formatUnits(deployerBalance, 18)} GX`);
  console.log("  (Founder 50M for vesting + Fair Launch 160M + AutoLiq 100K)");

  // ── Verify on Arbiscan ──
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting for block confirmations...");
    await token.deploymentTransaction()!.wait(5);

    console.log("Verifying contract on Arbiscan...");
    try {
      await run("verify:verify", {
        address,
        constructorArguments: [],
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
    contract: "GXToken",
    name: "GX Exchange",
    symbol: "GX",
    totalSupply: "1,000,000,000",
    address,
    txHash,
    deployer: deployer.address,
    network: network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString(),
    arbiscanToken: `https://arbiscan.io/token/${address}`,
    distributions: {
      emissions: { wallet: EMISSIONS_WALLET, amount: "388,900,000" },
      marketing: { wallet: MARKETING_WALLET, amount: "188,000,000" },
      airdrop: { wallet: AIRDROP_WALLET, amount: "150,000,000" },
      foundation: { wallet: FOUNDATION_WALLET, amount: "60,000,000" },
      grants: { wallet: GRANTS_WALLET, amount: "3,000,000" },
      deployer_remaining: "210,100,000 (Founder 50M + Fair Launch 160M + AutoLiq 100K)",
    },
  };

  const outPath = path.join(deploymentsDir, "gx-token.json");
  fs.writeFileSync(outPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("\nDeployment info saved to:", outPath);

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  NEXT STEP: Run deploy-vesting.ts to lock Founder tokens");
  console.log("  npx hardhat run scripts/deploy-vesting.ts --network arbitrumOne");
  console.log("═══════════════════════════════════════════════════");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
