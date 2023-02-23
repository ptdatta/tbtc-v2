import { HardhatUserConfig } from "hardhat/config"

import "@keep-network/hardhat-helpers"
import "@keep-network/hardhat-local-networks-config"
import "@nomiclabs/hardhat-waffle"
import "@nomiclabs/hardhat-etherscan"
import "hardhat-gas-reporter"
import "hardhat-contract-sizer"
import "hardhat-deploy"
import "@tenderly/hardhat-tenderly"
import "@typechain/hardhat"

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
    ],
  },

  paths: {
    artifacts: "./build",
  },

  networks: {
    hardhat: {
    },
    development: {
      url: "http://localhost:8545",
      chainId: 1101,
    },
    goerli: {
      url: process.env.CHAIN_API_URL || "",
      chainId: 5,
      accounts: process.env.ACCOUNTS_PRIVATE_KEYS
        ? process.env.ACCOUNTS_PRIVATE_KEYS.split(",")
        : undefined,
      tags: ["tenderly"],
    },
    mainnet: {
      url: process.env.CHAIN_API_URL || "",
      chainId: 1,
      accounts: process.env.ACCOUNTS_PRIVATE_KEYS
        ? process.env.ACCOUNTS_PRIVATE_KEYS.split(",")
        : undefined,
      tags: ["etherscan", "tenderly"],
    },
    goerliArbitrum: {
      url: process.env.CHAIN_API_URL || "",
      chainId: 421613,
      accounts: process.env.ACCOUNTS_PRIVATE_KEYS
        ? process.env.ACCOUNTS_PRIVATE_KEYS.split(",")
        : undefined,
      tags: ["tenderly"],
    },
    mainnetArbitrum: {
      url: process.env.CHAIN_API_URL || "",
      chainId: 42161,
      accounts: process.env.ACCOUNTS_PRIVATE_KEYS
        ? process.env.ACCOUNTS_PRIVATE_KEYS.split(",")
        : undefined,
      tags: ["arbiscan", "tenderly"],
    },
  },

  tenderly: {
    username: "thesis",
    project: "",
  },

  namedAccounts: {
    deployer: {
      default: 1,
      goerli: process.env.CONTRACT_OWNER_ADDRESS || "",
      goerliArbitrum: process.env.CONTRACT_OWNER_ADDRESS || "",
      mainnet: "",
      mainnetArbitrum: ""
    },
    governance: {
      default: 2,
      goerli: process.env.THRESHOLD_COUNCIL_ADDRESS || "",
      goerliArbitrum: process.env.THRESHOLD_COUNCIL_ADDRESS || "",
      mainnet: "", // Threshold Council
      mainnetArbitrum: "" // Threshold Council
    },
  },
  mocha: {
    timeout: 60_000,
  },
  typechain: {
    outDir: "typechain",
  },
}

export default config
