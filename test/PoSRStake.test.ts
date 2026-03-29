import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { PoSRStake, PoSRStakeFactory } from "../typechain-types";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("PoSRStake", function () {
  let posrStake: PoSRStake;
  let factory: PoSRStakeFactory;
  let owner: HardhatEthersSigner;
  let validator1: HardhatEthersSigner;
  let validator2: HardhatEthersSigner;
  let delegator1: HardhatEthersSigner;
  let slasher: HardhatEthersSigner;

  const minStakeAmount = ethers.parseEther("32");
  const unbondingPeriod = 14 * 24 * 60 * 60; // 14 days
  const jailPeriod = 7 * 24 * 60 * 60; // 7 days

  beforeEach(async function () {
    [owner, validator1, validator2, delegator1, slasher] = await ethers.getSigners();

    // Deploy implementation
    const PoSRStake = await ethers.getContractFactory("PoSRStake");
    const impl = await PoSRStake.deploy();

    // Deploy factory
    const PoSRStakeFactory = await ethers.getContractFactory("PoSRStakeFactory");
    factory = await PoSRStakeFactory.deploy(await impl.getAddress());

    // Deploy proxy
    await factory.deployPoSRStake(minStakeAmount, unbondingPeriod, jailPeriod, owner.address);
    const proxyAddress = await factory.deployedContracts(0);
    
    posrStake = await ethers.getContractAt("PoSRStake", proxyAddress);
    
    // Grant slasher role
    await posrStake.grantRole(await posrStake.SLASHER_ROLE(), slasher.address);
  });

  describe("Validator Creation", function () {
    it("Should create a validator successfully", async function () {
      const commissionRate = 1000; // 10%
      
      await expect(
        posrStake.connect(validator1).createValidator(
          "Validator1",
          "keybase:validator1",
          "https://validator1.com",
          "Best validator ever",
          commissionRate,
          { value: minStakeAmount }
        )
      )
        .to.emit(posrStake, "ValidatorCreated")
        .withArgs(validator1.address, "Validator1", commissionRate, minStakeAmount);

      const validator = await posrStake.validators(validator1.address);
      expect(validator.moniker).to.equal("Validator1");
      expect(validator.stakedAmount).to.equal(minStakeAmount);
      expect(validator.status).to.equal(0); // Active
      expect(await posrStake.isValidator(validator1.address)).to.be.true;
    });

    it("Should fail with insufficient stake", async function () {
      await expect(
        posrStake.connect(validator1).createValidator(
          "Validator1", "", "", "",
          1000,
          { value: ethers.parseEther("1") }
        )
      ).to.be.revertedWith("PoSR: insufficient stake amount");
    });

    it("Should fail with commission rate too high", async function () {
      await expect(
        posrStake.connect(validator1).createValidator(
          "Validator1", "", "", "",
          5000, // 50% > max 20%
          { value: minStakeAmount }
        )
      ).to.be.revertedWith("PoSR: commission rate too high");
    });

    it("Should fail without moniker", async function () {
      await expect(
        posrStake.connect(validator1).createValidator(
          "", "", "", "",
          1000,
          { value: minStakeAmount }
        )
      ).to.be.revertedWith("PoSR: moniker required");
    });

    it("Should fail to create validator twice", async function () {
      await posrStake.connect(validator1).createValidator(
        "Validator1", "", "", "", 1000,
        { value: minStakeAmount }
      );

      await expect(
        posrStake.connect(validator1).createValidator(
          "Validator2", "", "", "", 1000,
          { value: minStakeAmount }
        )
      ).to.be.revertedWith("PoSR: already a validator");
    });
  });

  describe("Staking", function () {
    beforeEach(async function () {
      await posrStake.connect(validator1).createValidator(
        "Validator1", "", "", "", 1000,
        { value: minStakeAmount }
      );
    });

    it("Should allow delegator to stake", async function () {
      const stakeAmount = ethers.parseEther("10");
      
      await expect(
        posrStake.connect(delegator1).stake(validator1.address, { value: stakeAmount })
      )
        .to.emit(posrStake, "Staked")
        .withArgs(validator1.address, delegator1.address, stakeAmount);

      const delegation = await posrStake.delegations(validator1.address, delegator1.address);
      expect(delegation.amount).to.equal(stakeAmount);
      
      const validator = await posrStake.validators(validator1.address);
      expect(validator.totalDelegations).to.equal(stakeAmount);
    });

    it("Should fail to stake to non-validator", async function () {
      await expect(
        posrStake.connect(delegator1).stake(delegator1.address, { value: ethers.parseEther("1") })
      ).to.be.revertedWith("PoSR: validator not active");
    });

    it("Should fail with zero stake", async function () {
      await expect(
        posrStake.connect(delegator1).stake(validator1.address, { value: 0 })
      ).to.be.revertedWith("PoSR: stake amount must be > 0");
    });
  });

  describe("Unbonding", function () {
    const stakeAmount = ethers.parseEther("10");

    beforeEach(async function () {
      await posrStake.connect(validator1).createValidator(
        "Validator1", "", "", "", 1000,
        { value: minStakeAmount }
      );
      await posrStake.connect(delegator1).stake(validator1.address, { value: stakeAmount });
    });

    it("Should start unbonding", async function () {
      const unbondAmount = ethers.parseEther("5");
      
      await expect(posrStake.connect(delegator1).startUnbonding(validator1.address, unbondAmount))
        .to.emit(posrStake, "UnbondingStarted")
        .withArgs(
          validator1.address,
          delegator1.address,
          unbondAmount,
          await time.latest() + unbondingPeriod
        );

      const delegation = await posrStake.delegations(validator1.address, delegator1.address);
      expect(delegation.amount).to.equal(stakeAmount - unbondAmount);
      expect(delegation.unbondingAmount).to.equal(unbondAmount);
    });

    it("Should complete unbonding after period", async function () {
      const unbondAmount = ethers.parseEther("5");
      
      await posrStake.connect(delegator1).startUnbonding(validator1.address, unbondAmount);
      
      // Advance time
      await time.increase(unbondingPeriod + 1);
      
      const balanceBefore = await ethers.provider.getBalance(delegator1.address);
      
      await expect(posrStake.connect(delegator1).completeUnbonding(validator1.address))
        .to.emit(posrStake, "UnbondingCompleted")
        .withArgs(validator1.address, delegator1.address, unbondAmount);

      const balanceAfter = await ethers.provider.getBalance(delegator1.address);
      expect(balanceAfter).to.be.gt(balanceBefore);
    });

    it("Should fail to complete unbonding early", async function () {
      const unbondAmount = ethers.parseEther("5");
      
      await posrStake.connect(delegator1).startUnbonding(validator1.address, unbondAmount);
      
      await expect(
        posrStake.connect(delegator1).completeUnbonding(validator1.address)
      ).to.be.revertedWith("PoSR: unbonding period not complete");
    });
  });

  describe("Slashing", function () {
    beforeEach(async function () {
      await posrStake.connect(validator1).createValidator(
        "Validator1", "", "", "", 1000,
        { value: minStakeAmount }
      );
    });

    it("Should slash a validator", async function () {
      const slashPercentage = 500n; // 5%
      const expectedSlash = (minStakeAmount * slashPercentage) / 10000n;
      
      await expect(
        posrStake.connect(slasher).slashValidator(validator1.address, "Double signing")
      )
        .to.emit(posrStake, "ValidatorSlashed")
        .withArgs(validator1.address, expectedSlash, "Double signing")
        .to.emit(posrStake, "ValidatorJailed");

      const validator = await posrStake.validators(validator1.address);
      expect(validator.stakedAmount).to.equal(minStakeAmount - expectedSlash);
      expect(validator.status).to.equal(2); // Jailed
    });

    it("Should allow unjail after jail period", async function () {
      await posrStake.connect(slasher).slashValidator(validator1.address, "Violation");
      
      await time.increase(jailPeriod + 1);
      
      await expect(posrStake.connect(validator1).unjail())
        .to.emit(posrStake, "ValidatorUnjailed")
        .withArgs(validator1.address);

      const validator = await posrStake.validators(validator1.address);
      expect(validator.status).to.equal(1); // Active
    });

    it("Should fail to unjail early", async function () {
      await posrStake.connect(slasher).slashValidator(validator1.address, "Violation");
      
      await expect(
        posrStake.connect(validator1).unjail()
      ).to.be.revertedWith("PoSR: jail period not complete");
    });
  });

  describe("Rewards", function () {
    beforeEach(async function () {
      await posrStake.connect(validator1).createValidator(
        "Validator1", "", "", "", 1000,
        { value: minStakeAmount }
      );
      
      // Add rewards to pool
      await posrStake.connect(owner).addRewards({ value: ethers.parseEther("100") });
      
      // Set reward rate
      await posrStake.connect(owner).setRewardPerSecond(ethers.parseEther("0.001"));
    });

    it("Should accumulate rewards over time", async function () {
      const stakeAmount = ethers.parseEther("10");
      await posrStake.connect(delegator1).stake(validator1.address, { value: stakeAmount });
      
      // Advance time
      await time.increase(3600); // 1 hour
      
      const pendingRewards = await posrStake.getPendingRewards(validator1.address, delegator1.address);
      expect(pendingRewards).to.be.gt(0);
    });

    it("Should claim rewards", async function () {
      const stakeAmount = ethers.parseEther("10");
      await posrStake.connect(delegator1).stake(validator1.address, { value: stakeAmount });
      
      await time.increase(3600);
      
      const balanceBefore = await ethers.provider.getBalance(delegator1.address);
      
      await posrStake.connect(delegator1).claimRewards(validator1.address);
      
      const balanceAfter = await ethers.provider.getBalance(delegator1.address);
      expect(balanceAfter).to.be.gt(balanceBefore);
    });
  });

  describe("Admin Functions", function () {
    it("Should update parameters", async function () {
      const newMinStake = ethers.parseEther("64");
      const newUnbonding = 21 * 24 * 60 * 60;
      const newJail = 14 * 24 * 60 * 60;
      
      await posrStake.connect(owner).updateParameters(newMinStake, newUnbonding, newJail);
      
      expect(await posrStake.minStakeAmount()).to.equal(newMinStake);
      expect(await posrStake.unbondingPeriod()).to.equal(newUnbonding);
      expect(await posrStake.jailPeriod()).to.equal(newJail);
    });

    it("Should pause and unpause", async function () {
      await posrStake.connect(owner).pause();
      
      await expect(
        posrStake.connect(validator1).createValidator(
          "Validator1", "", "", "", 1000,
          { value: minStakeAmount }
        )
      ).to.be.revertedWithCustomError(posrStake, "EnforcedPause");
      
      await posrStake.connect(owner).unpause();
      
      await expect(
        posrStake.connect(validator1).createValidator(
          "Validator1", "", "", "", 1000,
          { value: minStakeAmount }
        )
      ).to.not.be.reverted;
    });
  });
});
