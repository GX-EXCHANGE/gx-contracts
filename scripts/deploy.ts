import { ethers, run, network } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying SynticToken with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  const SynticToken = await ethers.getContractFactory("SynticToken");
  const token = await SynticToken.deploy();
  await token.waitForDeployment();

  const address = await token.getAddress();
  console.log("SynticToken deployed to:", address);

  // Verify on Etherscan if not on a local network
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("Waiting for block confirmations...");
    await token.deploymentTransaction()!.wait(5);

    console.log("Verifying contract on Etherscan...");
    await run("verify:verify", {
      address,
      constructorArguments: [],
    });
    console.log("Contract verified!");
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
