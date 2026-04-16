import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
  const TREASURY = "0x678E4d4906883A6694fdFE35ebd8211A508ffD68";

  console.log("Deploying GXPredictionV3...");
  const F = await ethers.getContractFactory("GXPredictionV3");
  const c = await F.deploy(USDC, TREASURY, deployer.address, 100);
  await c.waitForDeployment();
  const addr = await c.getAddress();
  const tx = c.deploymentTransaction()?.hash;
  console.log("GXPredictionV3:", addr);
  console.log("Tx:", tx);

  if (network.name !== "hardhat" && network.name !== "localhost") {
    await c.deploymentTransaction()!.wait(5);
    try {
      await run("verify:verify", { address: addr, constructorArguments: [USDC, TREASURY, deployer.address, 100] });
      console.log("Verified!");
    } catch (e: any) { console.warn("Verify:", e.message); }
  }

  const dir = path.join(__dirname, "deployments");
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "gx-prediction-v3.json"), JSON.stringify({
    contract: "GXPredictionV3", address: addr, txHash: tx,
    deployer: deployer.address, network: network.name,
    deployedAt: new Date().toISOString(),
    arbiscan: `https://arbiscan.io/address/${addr}`,
  }, null, 2));
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
