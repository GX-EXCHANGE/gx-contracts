import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

describe("GXPredictionV3", function () {
  async function deployFixture() {
    const [owner, operator, user1, user2, feeRecipient] = await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20 = await ethers.getContractFactory("GXToken");
    const usdc = await MockERC20.deploy();
    await usdc.waitForDeployment();

    // Give users USDC
    await usdc.transfer(user1.address, ethers.parseEther("100000"));
    await usdc.transfer(user2.address, ethers.parseEther("100000"));

    // Deploy prediction market
    const GXPredictionV3 = await ethers.getContractFactory("GXPredictionV3");
    const prediction = await GXPredictionV3.deploy(
      await usdc.getAddress(),
      feeRecipient.address,
      operator.address,
      100 // 1% fee
    );
    await prediction.waitForDeployment();

    return { prediction, usdc, owner, operator, user1, user2, feeRecipient };
  }

  describe("Market Creation", function () {
    it("operator can create a market", async function () {
      const { prediction, operator } = await loadFixture(deployFixture);

      await prediction.connect(operator).createMarket(
        "Will BTC hit $200K by end of 2026?",
        ethers.keccak256(ethers.toUtf8Bytes("btc-200k-2026")),
        Math.floor(Date.now() / 1000) + 86400 * 30,
        operator.address // operator as oracle for manual settlement
      );

      const market = await prediction.getMarket(0);
      console.log(`  Market created: "${market.question}"`);
      expect(market.question).to.include("BTC");
    });

    it("non-operator cannot create market", async function () {
      const { prediction, user1 } = await loadFixture(deployFixture);

      await expect(
        prediction.connect(user1).createMarket("Test?", ethers.keccak256(ethers.toUtf8Bytes("test")), Math.floor(Date.now() / 1000) + 86400, operator.address)
      ).to.be.reverted;
    });
  });

  describe("Betting", function () {
    it("users can bet YES", async function () {
      const { prediction, usdc, operator, user1 } = await loadFixture(deployFixture);

      await prediction.connect(operator).createMarket("Will ETH hit $10K?", ethers.keccak256(ethers.toUtf8Bytes("ETH target")), Math.floor(Date.now() / 1000) + 86400, operator.address);

      const betAmount = ethers.parseEther("1000");
      await usdc.connect(user1).approve(await prediction.getAddress(), betAmount);
      await prediction.connect(user1).splitPosition(0, betAmount); // Split into YES + NO tokens

      // User should have YES and NO tokens (ERC-1155)
      const yesBalance = await prediction.balanceOf(user1.address, 0); // YES token ID
      const noBalance = await prediction.balanceOf(user1.address, 1);  // NO token ID
      console.log(`  YES tokens: ${ethers.formatEther(yesBalance)}`);
      console.log(`  NO tokens: ${ethers.formatEther(noBalance)}`);
      expect(yesBalance).to.be.gt(0);
      expect(noBalance).to.be.gt(0);
    });

    it("users can merge YES + NO back to USDC", async function () {
      const { prediction, usdc, operator, user1 } = await loadFixture(deployFixture);

      await prediction.connect(operator).createMarket("Test merge?", ethers.keccak256(ethers.toUtf8Bytes("test")), Math.floor(Date.now() / 1000) + 86400, operator.address);

      const amount = ethers.parseEther("500");
      await usdc.connect(user1).approve(await prediction.getAddress(), amount);
      await prediction.connect(user1).splitPosition(0, amount);

      const balanceBefore = await usdc.balanceOf(user1.address);
      await prediction.connect(user1).mergePositions(0, amount);
      const balanceAfter = await usdc.balanceOf(user1.address);

      console.log(`  Merged back: ${ethers.formatEther(balanceAfter - balanceBefore)} USDC recovered`);
      expect(balanceAfter).to.be.gt(balanceBefore);
    });
  });

  describe("Settlement", function () {
    it("operator settles market YES — YES holders win", async function () {
      const { prediction, usdc, operator, user1, user2 } = await loadFixture(deployFixture);

      // Create market
      await prediction.connect(operator).createMarket("Will SOL hit $500?", ethers.keccak256(ethers.toUtf8Bytes("SOL")), Math.floor(Date.now() / 1000) + 86400, operator.address);

      // User1 splits and keeps YES, sells NO
      const amount = ethers.parseEther("1000");
      await usdc.connect(user1).approve(await prediction.getAddress(), amount);
      await prediction.connect(user1).splitPosition(0, amount);

      // User1 transfers NO tokens to User2 (simulating a trade)
      const noTokenId = 1; // NO token for market 0
      const noTokens = await prediction.balanceOf(user1.address, noTokenId);
      await prediction.connect(user1).safeTransferFrom(user1.address, user2.address, noTokenId, noTokens, "0x");

      // Settle: YES wins
      await time.increase(86401);
      await prediction.connect(operator).resolveMarket(0, 1); // true = YES wins

      // User1 redeems YES tokens
      const u1Before = await usdc.balanceOf(user1.address);
      await prediction.connect(user1).redeemWinnings(0);
      const u1After = await usdc.balanceOf(user1.address);

      console.log(`  User1 (YES holder) received: ${ethers.formatEther(u1After - u1Before)} USDC`);
      expect(u1After).to.be.gt(u1Before);

      // User2 tries to redeem NO tokens — gets nothing
      const u2Before = await usdc.balanceOf(user2.address);
      await prediction.connect(user2).redeemWinnings(0);
      const u2After = await usdc.balanceOf(user2.address);

      console.log(`  User2 (NO holder) received: ${ethers.formatEther(u2After - u2Before)} USDC`);
      expect(u2After - u2Before).to.equal(0n);
    });

    it("operator settles market NO — NO holders win", async function () {
      const { prediction, usdc, operator, user1, user2 } = await loadFixture(deployFixture);

      await prediction.connect(operator).createMarket("Test NO wins?", ethers.keccak256(ethers.toUtf8Bytes("test")), Math.floor(Date.now() / 1000) + 86400, operator.address);

      const amount = ethers.parseEther("2000");
      await usdc.connect(user1).approve(await prediction.getAddress(), amount);
      await prediction.connect(user1).splitPosition(0, amount);

      // User1 keeps NO, sends YES to User2
      const yesTokenId = 0;
      const yesTokens = await prediction.balanceOf(user1.address, yesTokenId);
      await prediction.connect(user1).safeTransferFrom(user1.address, user2.address, yesTokenId, yesTokens, "0x");

      // Settle: NO wins
      await time.increase(86401);
      await prediction.connect(operator).resolveMarket(0, 2);

      // User1 (NO holder) redeems
      const u1Before = await usdc.balanceOf(user1.address);
      await prediction.connect(user1).redeemWinnings(0);
      const u1After = await usdc.balanceOf(user1.address);

      console.log(`  NO holder received: ${ethers.formatEther(u1After - u1Before)} USDC`);
      expect(u1After).to.be.gt(u1Before);
    });
  });

  describe("Fee Collection", function () {
    it("fees go to fee recipient on settlement", async function () {
      const { prediction, usdc, operator, user1, feeRecipient } = await loadFixture(deployFixture);

      await prediction.connect(operator).createMarket("Fee test?", ethers.keccak256(ethers.toUtf8Bytes("test")), Math.floor(Date.now() / 1000) + 86400, operator.address);

      const amount = ethers.parseEther("10000");
      await usdc.connect(user1).approve(await prediction.getAddress(), amount);
      await prediction.connect(user1).splitPosition(0, amount);

      const feeBefore = await usdc.balanceOf(feeRecipient.address);
      await time.increase(86401);
      await prediction.connect(operator).resolveMarket(0, 1);
      await prediction.connect(user1).redeemWinnings(0);
      const feeAfter = await usdc.balanceOf(feeRecipient.address);

      console.log(`  Fees collected: ${ethers.formatEther(feeAfter - feeBefore)} USDC`);
      // 1% of 10,000 = 100 USDC fee
    });
  });
});
