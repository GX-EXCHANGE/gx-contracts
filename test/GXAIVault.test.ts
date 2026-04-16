import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("GXAIVault", function () {
  async function deployFixture() {
    const [owner, strategist, user1, user2, treasury] = await ethers.getSigners();

    // Deploy mock USDC (6 decimals)
    const MockERC20 = await ethers.getContractFactory("GXToken");
    const usdc = await MockERC20.deploy(); // 18 decimals, we'll treat as USDC for testing
    await usdc.waitForDeployment();

    // Transfer USDC to users
    await usdc.transfer(user1.address, ethers.parseEther("100000"));
    await usdc.transfer(user2.address, ethers.parseEther("100000"));
    await usdc.transfer(strategist.address, ethers.parseEther("1000000"));

    // Deploy vault
    const depositCap = ethers.parseEther("10000000"); // 10M
    const GXAIVault = await ethers.getContractFactory("GXAIVault");
    const vault = await GXAIVault.deploy(
      await usdc.getAddress(),
      "GX AI Vault",
      "gxUSDC",
      treasury.address,
      depositCap,
      strategist.address,
      owner.address
    );
    await vault.waitForDeployment();

    return { vault, usdc, owner, strategist, user1, user2, treasury };
  }

  describe("Deposit & Withdraw", function () {
    it("should accept deposits and mint shares", async function () {
      const { vault, usdc, user1 } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("10000");

      await usdc.connect(user1).approve(await vault.getAddress(), amount);
      await vault.connect(user1).deposit(amount, user1.address);

      const shares = await vault.balanceOf(user1.address);
      expect(shares).to.be.gt(0);
      console.log(`  Deposited: 10,000 USDC → ${ethers.formatEther(shares)} shares`);
    });

    it("should allow withdrawal", async function () {
      const { vault, usdc, user1 } = await loadFixture(deployFixture);
      const amount = ethers.parseEther("10000");

      await usdc.connect(user1).approve(await vault.getAddress(), amount);
      await vault.connect(user1).deposit(amount, user1.address);

      const shares = await vault.balanceOf(user1.address);
      const balanceBefore = await usdc.balanceOf(user1.address);

      await vault.connect(user1).redeem(shares, user1.address, user1.address);

      const balanceAfter = await usdc.balanceOf(user1.address);
      expect(balanceAfter).to.be.gt(balanceBefore);
      console.log(`  Withdrew: ${ethers.formatEther(shares)} shares → ${ethers.formatEther(balanceAfter - balanceBefore)} USDC`);
    });

    it("should reject deposits above cap", async function () {
      const { vault, usdc, user1 } = await loadFixture(deployFixture);
      const tooMuch = ethers.parseEther("20000000"); // 20M, cap is 10M

      await usdc.connect(user1).approve(await vault.getAddress(), tooMuch);
      // This should revert
      await expect(vault.connect(user1).deposit(tooMuch, user1.address)).to.be.reverted;
    });

    it("should handle multiple depositors", async function () {
      const { vault, usdc, user1, user2 } = await loadFixture(deployFixture);

      await usdc.connect(user1).approve(await vault.getAddress(), ethers.parseEther("50000"));
      await vault.connect(user1).deposit(ethers.parseEther("50000"), user1.address);

      await usdc.connect(user2).approve(await vault.getAddress(), ethers.parseEther("30000"));
      await vault.connect(user2).deposit(ethers.parseEther("30000"), user2.address);

      const shares1 = await vault.balanceOf(user1.address);
      const shares2 = await vault.balanceOf(user2.address);
      const totalAssets = await vault.totalAssets();

      console.log(`  User1: ${ethers.formatEther(shares1)} shares`);
      console.log(`  User2: ${ethers.formatEther(shares2)} shares`);
      console.log(`  Total assets: ${ethers.formatEther(totalAssets)} USDC`);

      expect(totalAssets).to.equal(ethers.parseEther("80000"));
    });
  });

  describe("Strategy Manager", function () {
    it("only strategy manager can deploy funds", async function () {
      const { vault, usdc, user1 } = await loadFixture(deployFixture);

      await usdc.connect(user1).approve(await vault.getAddress(), ethers.parseEther("10000"));
      await vault.connect(user1).deposit(ethers.parseEther("10000"), user1.address);

      // user1 should NOT be able to deploy funds
      await expect(vault.connect(user1).deployToStrategy(ethers.parseEther("5000"))).to.be.reverted;
    });

    it("strategy manager can deploy and return funds with profit", async function () {
      const { vault, usdc, user1, strategist } = await loadFixture(deployFixture);

      // User deposits
      await usdc.connect(user1).approve(await vault.getAddress(), ethers.parseEther("10000"));
      await vault.connect(user1).deposit(ethers.parseEther("10000"), user1.address);

      // Strategist deploys funds (simulate AI taking funds to trade)
      await vault.connect(strategist).deployToStrategy(ethers.parseEther("8000"));

      // Simulate profit: strategist returns more than taken
      await usdc.connect(strategist).approve(await vault.getAddress(), ethers.parseEther("9000"));
      await vault.connect(strategist).returnFromStrategy(ethers.parseEther("9000")); // $1000 profit

      const totalAssets = await vault.totalAssets();
      console.log(`  After strategy: ${ethers.formatEther(totalAssets)} USDC (started with 10,000)`);
      expect(totalAssets).to.be.gt(ethers.parseEther("10000"));
    });
  });

  describe("Emergency", function () {
    it("owner can pause", async function () {
      const { vault, owner } = await loadFixture(deployFixture);
      await vault.connect(owner).pause();
      expect(await vault.paused()).to.be.true;
    });

    it("deposits rejected when paused", async function () {
      const { vault, usdc, owner, user1 } = await loadFixture(deployFixture);
      await vault.connect(owner).pause();

      await usdc.connect(user1).approve(await vault.getAddress(), ethers.parseEther("1000"));
      await expect(vault.connect(user1).deposit(ethers.parseEther("1000"), user1.address)).to.be.reverted;
    });
  });
});
