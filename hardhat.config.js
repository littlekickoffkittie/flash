require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  networks: {
    sepoliaFork: {
      url: "https://rpc.buildbear.io/determined-psylocke-f7725a1e",
      accounts: ["0xc95e417da658e1b70733a410d88911ef547c54a22247b68f5a9763c090cb46ac"]
    }
  }
};
