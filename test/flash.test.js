const { expect } = require("chai");
const { ethers } = require("hardhat");
const { parseEther } = require("ethers");

describe("EnhancedFlashLoanArbitrage", function () {
  let FlashLoanArbitrage, flashLoanArbitrage, owner, addr1, addr2;

  this.timeout(60000); // Increase timeout to 60 seconds

  beforeEach(async function () {
    FlashLoanArbitrage = await ethers.getContractFactory("EnhancedFlashLoanArbitrage");
    [owner, addr1, addr2] = await ethers.getSigners();

    // Deploy the contract with mock addresses
    flashLoanArbitrage = await FlashLoanArbitrage.deploy(
      "0x0000000000000000000000000000000000000001", // Mock lendingPool address
      "0x0000000000000000000000000000000000000002", // Mock uniswapRouter address
      "0x0000000000000000000000000000000000000003", // Mock sushiswapRouter address
      "0x0000000000000000000000000000000000000004"  // Mock priceOracle address
    );

    await flashLoanArbitrage.deployed();

    // Removed await flashLoanArbitrage.deployed(); for ethers.js v6 compatibility
  });

  it("Should set the right owner", async function () {
    expect(await flashLoanArbitrage.owner()).to.equal(owner.address);
  });

  it("Should update config", async function () {
    await flashLoanArbitrage.updateConfig(
      100, // maxSlippage
      20,  // minProfitBps
      60000000000, // maxGasPrice
      parseEther("200"), // maxLoanAmount
      false // dynamicSlippage
    );

    expect((await flashLoanArbitrage.config()).maxSlippage).to.equal(100);
  });

  it("Should whitelist token", async function () {
    await flashLoanArbitrage.whitelistToken(
      addr1.address,
      parseEther("1000"), // maxLoanAmount
      50,      // customSlippage
      true     // requiresOracle
    );

    expect((await flashLoanArbitrage.tokenConfigs(addr1.address)).isWhitelisted).to.equal(true);
  });

  describe("Access control", function () {
    it("Should revert if non-owner tries to update config", async function () {
      await expect(
        flashLoanArbitrage.connect(addr1).updateConfig(100, 20, 60000000000, parseEther("200"), false)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should revert if non-owner tries to whitelist token", async function () {
      await expect(
        flashLoanArbitrage.connect(addr1).whitelistToken(addr2.address, parseEther("1000"), 50, true)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  // Additional tests for executeArbitrage and executeOperation would require mocks or integration tests
  // which are complex to implement here due to external dependencies and flash loan mechanics.
});
