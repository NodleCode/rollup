import { HardhatUserConfig, subtask } from "hardhat/config";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names";

import "hardhat-storage-layout";
import "@matterlabs/hardhat-zksync-node";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-deploy";
import "@matterlabs/hardhat-zksync-verify";
import "@nomicfoundation/hardhat-foundry";

// Exclude files that can't compile under zksolc:
//   - SwarmRegistryL1Upgradeable: uses SSTORE2/EXTCODECOPY (L1-only by design — deploy
//     via the dedicated L1 toolchain, not Hardhat-zksync).
//   - FleetIdentity.t.sol: bytecode size exceeds the 64K-instruction EraVM limit
//     (test-only).
//   - TestUpgradeOnAnvil.s.sol: uses EXTCODECOPY for Anvil-only state poking.
const ZKSOLC_EXCLUDED = [
  "SwarmRegistryL1Upgradeable.sol",
  "FleetIdentity.t.sol",
  "TestUpgradeOnAnvil.s.sol",
];

subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(
  async (_args, _hre, runSuper) => {
    const paths: string[] = await runSuper();
    return paths.filter(
      (p) => !ZKSOLC_EXCLUDED.some((needle) => p.endsWith(needle)),
    );
  },
);

const config: HardhatUserConfig = {
  defaultNetwork: "zkSyncSepoliaTestnet",
  networks: {
    zkSyncSepoliaTestnet: {
      url: "https://sepolia.era.zksync.dev",
      ethNetwork: "sepolia",
      zksync: true,
      verifyURL:
        "https://explorer.sepolia.era.zksync.dev/contract_verification",
    },
    zkSyncMainnet: {
      url: "https://mainnet.era.zksync.io",
      ethNetwork: "mainnet",
      zksync: true,
      verifyURL:
        "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
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
    // Aligned with foundry-zksync and the explorer verification settings
    // (zksolc v1.5.15, optimizer mode 3) so hardhat-deployed contracts verify
    // consistently — including the bare ERC1967Proxy via the standard-JSON path.
    version: "1.5.15",
    settings: {
      // find all available options in the official documentation
      // https://era.zksync.io/docs/tools/hardhat/hardhat-zksync-solc.html#configuration
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  solidity: {
    version: "0.8.26",
  },
  paths: {
    sources: "src",
    deployPaths: ["hardhat-deploy"],
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
};

export default config;
