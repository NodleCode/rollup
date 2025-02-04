
import { HardhatUserConfig } from "hardhat/config";

import "hardhat-storage-layout";
import "@matterlabs/hardhat-zksync-node";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-deploy";
import "@matterlabs/hardhat-zksync-verify";
import "@nomicfoundation/hardhat-foundry";

const config: HardhatUserConfig = {
    defaultNetwork: "zkSyncSepoliaTestnet",
    networks: {
        zkSyncSepoliaTestnet: {
            url: "https://sepolia.era.zksync.dev",
            ethNetwork: "sepolia",
            zksync: true,
            verifyURL: "https://explorer.sepolia.era.zksync.dev/contract_verification",
        },
        zkSyncMainnet: {
            url: "https://mainnet.era.zksync.io",
            ethNetwork: "mainnet",
            zksync: true,
            verifyURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
        },
        localDockerNode: {
            url: "http://localhost:3050",
            ethNetwork: "http://localhost:8545",
            zksync: true,
        },
        inMemoryNode: {
            url: "http://127.0.0.1:8011",
            ethNetwork: "localhost", // in-memory node doesn't support eth node; removing this line will cause an error
            zksync: true,
        },
        hardhat: {
            zksync: true,
        },
    },
    zksolc: {
        version: "1.4.1",
        settings: {
            // find all available options in the official documentation
            // https://era.zksync.io/docs/tools/hardhat/hardhat-zksync-solc.html#configuration
        },
    },
    solidity: {
        version: "0.8.23",
    },
    paths: {
        sources: "src",        
    },
    etherscan: {
        apiKey: process.env.ETHERSCAN_API_KEY,
    }
};

export default config;
