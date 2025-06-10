const { expect } = require("chai");
const { ethers } = require("hardhat");
const { faker } = require("@faker-js/faker");

describe("Arbitrage", function () {
  this.timeout(60000); // Increase timeout to 60 seconds

  let arbitrage, owner;

  beforeEach(async function () {
    const Arbitrage = await ethers.getContractFactory("Arbitrage");
    [owner] = await ethers.getSigners();
    arbitrage = await Arbitrage.deploy();
    await arbitrage.deployed();
  });

  it("should simulate arbitrage with random prices", async function () {
    // Generate random token prices with Faker
    const priceA = faker.finance.amount(0.1, 10, 4); // Token A: $0.1 to $10
    const priceB = faker.finance.amount(0.1, 10, 4); // Token B: $0.1 to $10
    const amount = 1000; // Trade 1000 units

    // Set mock prices in contract (convert to wei-like units if needed)
    await arbitrage.setMockPrices(
      ethers.utils.parseUnits(priceA, 18),
      ethers.utils.parseUnits(priceB, 18)
    );

    // Test arbitrage logic
    const profit = await arbitrage.executeArbitrage(amount);
    console.log(`Price A: ${priceA}, Price B: ${priceB}, Profit: ${profit}`);

    if (priceA < priceB) {
      expect(profit).to.be.above(0);
    } else {
      expect(profit).to.equal(0);
    }
  });

  it("should handle high slippage", async function () {
    const priceA = faker.finance.amount(0.1, 10, 4);
    const priceB = (parseFloat(priceA) * 1.01).toFixed(4); // Only 1% price difference
    await arbitrage.setMockPrices(
      ethers.utils.parseUnits(priceA, 18),
      ethers.utils.parseUnits(priceB, 18)
    );
    const profit = await arbitrage.executeArbitrage(1000);
    expect(profit).to.equal(0); // Too small for profit
  });
});
