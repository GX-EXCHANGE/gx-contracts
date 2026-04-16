import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== TESTNET V2 — Using our own TestUSDC ===");
  console.log("Deployer:", deployer.address);

  const TEST_USDC = "0xA57744C4b421c392eBFeC4fe3332669FEF3Cbf5F";
  const depositCap = ethers.parseEther("100000000"); // 100M cap

  // 1. GXAIVault
  console.log("\n--- GXAIVault ---");
  const Vault = await ethers.getContractFactory("GXAIVault");
  const vault = await Vault.deploy(
    TEST_USDC, "GX AI Vault (Testnet)", "tgxUSDC",
    deployer.address, depositCap, deployer.address, deployer.address
  );
  await vault.waitForDeployment();
  console.log("GXAIVault:", await vault.getAddress());

  // 2. GXPredictionV3
  console.log("\n--- GXPredictionV3 ---");
  const Pred = await ethers.getContractFactory("GXPredictionV3");
  const pred = await Pred.deploy(TEST_USDC, deployer.address, deployer.address, 100);
  await pred.waitForDeployment();
  console.log("GXPredictionV3:", await pred.getAddress());

  // Verify
  await pred.deploymentTransaction()!.wait(5);
  try { await run("verify:verify", { address: await vault.getAddress(), constructorArguments: [TEST_USDC, "GX AI Vault (Testnet)", "tgxUSDC", deployer.address, depositCap, deployer.address, deployer.address] }); } catch(e: any) { console.warn(e.message); }
  try { await run("verify:verify", { address: await pred.getAddress(), constructorArguments: [TEST_USDC, deployer.address, deployer.address, 100] }); } catch(e: any) { console.warn(e.message); }

  // Save
  const info = {
    network: network.name, deployedAt: new Date().toISOString(),
    TestUSDC: TEST_USDC,
    GXAIVault: await vault.getAddress(),
    GXPredictionV3: await pred.getAddress(),
    deployer: deployer.address,
    note: "Both use our own TestUSDC (1B supply). Deployer is operator + strategy manager."
  };
  const dir = path.join(__dirname, "deployments");
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "testnet-v2.json"), JSON.stringify(info, null, 2));

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  TestUSDC:       ", TEST_USDC);
  console.log("  GXAIVault:      ", await vault.getAddress());
  console.log("  GXPredictionV3: ", await pred.getAddress());
  console.log("═══════════════════════════════════════════════════");
}

main().catch(console.error);
