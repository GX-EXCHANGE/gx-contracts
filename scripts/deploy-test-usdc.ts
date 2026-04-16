import { ethers, network } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying TestUSDC on", network.name);

  const Token = await ethers.getContractFactory("GXToken");
  const token = await Token.deploy();
  await token.waitForDeployment();
  const addr = await token.getAddress();

  const bal = await token.balanceOf(deployer.address);
  console.log("TestUSDC:", addr);
  console.log("Balance:", ethers.formatEther(bal), "tokens (1 billion)");
  console.log("\nUse this address for GXAIVault and GXPredictionV3 testing");
  console.log("You can transfer to 100 test wallets for bet simulation");
}

main().catch(console.error);
