import { expect } from "chai";
import { ethers } from "hardhat";
import { SynticToken } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("SynticToken", function () {
  let token: SynticToken;
  let owner: SignerWithAddress;
  let addr1: SignerWithAddress;

  beforeEach(async function () {
    [owner, addr1] = await ethers.getSigners();
    const SynticToken = await ethers.getContractFactory("SynticToken");
    token = await SynticToken.deploy();
  });

  describe("Deployment", function () {
    it("should have correct name and symbol", async function () {
      expect(await token.name()).to.equal("Syntic");
      expect(await token.symbol()).to.equal("SYNTIC");
    });

    it("should mint 1 billion tokens to deployer", async function () {
      const totalSupply = await token.totalSupply();
      const expectedSupply = ethers.parseEther("1000000000");
      expect(totalSupply).to.equal(expectedSupply);
      expect(await token.balanceOf(owner.address)).to.equal(expectedSupply);
    });

    it("should set deployer as owner", async function () {
      expect(await token.owner()).to.equal(owner.address);
    });
  });

  describe("Burn", function () {
    it("should allow token holders to burn their tokens", async function () {
      const burnAmount = ethers.parseEther("1000");
      await token.burn(burnAmount);
      const expectedSupply = ethers.parseEther("1000000000") - burnAmount;
      expect(await token.totalSupply()).to.equal(expectedSupply);
    });

    it("should allow approved addresses to burnFrom", async function () {
      const burnAmount = ethers.parseEther("500");
      await token.approve(addr1.address, burnAmount);
      await token.connect(addr1).burnFrom(owner.address, burnAmount);
      const expectedSupply = ethers.parseEther("1000000000") - burnAmount;
      expect(await token.totalSupply()).to.equal(expectedSupply);
    });
  });

  describe("Permit", function () {
    it("should support EIP-2612 permit", async function () {
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      const nonce = await token.nonces(owner.address);
      const name = await token.name();
      const chainId = (await ethers.provider.getNetwork()).chainId;

      const domain = {
        name,
        version: "1",
        chainId,
        verifyingContract: await token.getAddress(),
      };

      const types = {
        Permit: [
          { name: "owner", type: "address" },
          { name: "spender", type: "address" },
          { name: "value", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = ethers.parseEther("100");
      const message = {
        owner: owner.address,
        spender: addr1.address,
        value,
        nonce,
        deadline,
      };

      const signature = await owner.signTypedData(domain, types, message);
      const { v, r, s } = ethers.Signature.from(signature);

      await token.permit(owner.address, addr1.address, value, deadline, v, r, s);
      expect(await token.allowance(owner.address, addr1.address)).to.equal(value);
    });
  });

  describe("Transfer", function () {
    it("should transfer tokens between accounts", async function () {
      const amount = ethers.parseEther("1000");
      await token.transfer(addr1.address, amount);
      expect(await token.balanceOf(addr1.address)).to.equal(amount);
    });
  });
});
