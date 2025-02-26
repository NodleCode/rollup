require("dotenv").config();
import {
  EthereumProject,
  EthereumDatasourceKind,
  EthereumHandlerKind,
} from "@subql/types-ethereum";

const project: EthereumProject = {
  specVersion: "1.0.0",
  version: "0.0.1",
  name: "Nodle-zksync-subquery",
  description: "__",
  runner: {
    node: {
      name: "@subql/node-ethereum",
      version: ">=3.0.0",
      options: {
        unsafe: true,
      },
    },
    query: {
      name: "@subql/query",
      version: "*",
    },
  },
  schema: {
    file: "./schema.graphql",
  },
  network: {
    chainId: "300", // zKsync sepolia testnet
    endpoint: [
      process.env.ZKSYNC_TESTNET_RPC!,
      "https://sepolia.era.zksync.dev",
    ],
  },
  dataSources: [
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 1993364, // This is the block that the contract was deployed on
      options: {
        abi: "ClickContentSign",
        address: "0x999368030Ba79898E83EaAE0E49E89B7f6410940",
      },
      assets: new Map([
        [
          "ClickContentSign",
          {
            file: "./abis/ClickContentSign.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleTransfer",
            filter: {
              topics: ["Transfer(address,address,uint256)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 1993364, // This is the block that the contract was deployed on
      options: {
        abi: "ClickContentSign",
        address: "0x195e4E251c41e8Ae9E9E961366C73e2CFbfB115A",
      },
      assets: new Map([
        [
          "ClickContentSign",
          {
            file: "./abis/ClickContentSign.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleTransfer",
            filter: {
              topics: ["Transfer(address,address,uint256)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 2178049, // This is the block that the contract was deployed on
      options: {
        abi: "NODL",
        address: "0xb4B74C2BfeA877672B938E408Bae8894918fE41C",
      },
      assets: new Map([
        [
          "NODL",
          {
            file: "./abis/NODL.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleERC20Approval",
            filter: {
              topics: ["Approval(address,address,uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleERC20Transfer",
            filter: {
              topics: ["Transfer(address,address,uint256)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 2157320,
      options: {
        abi: "NODLMigration",
        address: "0x1427d38B967435a3F8f476Cda0bc4F51fe66AF4D",
      },
      assets: new Map([
        [
          "NODLMigration",
          {
            file: "./abis/NODLMigration.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleProposal",
            filter: {
              topics: ["VoteStarted(bytes32, address, address, uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleWithdrawn",
            filter: {
              topics: ["Withdrawn(bytes32, address, uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleVote",
            filter: {
              topics: ["Voted(bytes32, address)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 3001690, // This is the block that the contract was deployed on
      options: {
        abi: "MigrationNFT",
        address: "0x9Fed2d216DBE36928613812400Fd1B812f118438",
      },
      assets: new Map([
        [
          "MigrationNFT",
          {
            file: "./abis/MigrationNFT.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleNFTTransfer",
            filter: {
              topics: ["Transfer(address,address,uint256)"],
            },
          },
        ],
      },
    },
    //handleGrants
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 3548139, // This is the block that the contract was deployed on
      options: {
        abi: "Grants",
        address: "0x66f762DB62E5D8609317436e8F2784c5ACBC9c61",
      },
      assets: new Map([
        [
          "Grants",
          {
            file: "./abis/Grants.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleClaimed",
            filter: {
              topics: ["Claimed(address, uint256, uint256, uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleRenounced",
            filter: {
              topics: ["Renounced(address, address, uint256, uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleVestingScheduleAdded",
            filter: {
              topics: [
                "VestingScheduleAdded(address,tuple(address,uint256,uint256,uint32,uint256))",
              ],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleVestingSchedulesCanceled",
            filter: {
              topics: [
                "VestingSchedulesCanceled(address, address, uint256, uint256)",
              ],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 3548120, // This is the block that the contract was deployed on
      options: {
        abi: "GrantsMigration",
        address: "0xED90FDAB958AC7e4942f51b9175B76c8e181c5Cb",
      },
      assets: new Map([
        [
          "GrantsMigration",
          {
            file: "./abis/GrantsMigration.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleGrantsVoteStarted",
            filter: {
              topics: ["VoteStarted(bytes32, address, address, uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleGranted",
            filter: {
              topics: ["Granted(bytes32, address, uint256, uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleGrantsVoted",
            filter: {
              topics: ["Voted(bytes32, address)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 3798170, // This is the block that the contract was deployed on
      options: {
        abi: "Rewards",
        address: "0xba8a8ff7E7332f7e05205Ec9fC927965435C552c",
      },
      assets: new Map([
        [
          "Rewards",
          {
            file: "./abis/Rewards.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Call,
            handler: "handleMintReward",
            filter: {
              function: "mintReward((address,uint256,uint256),bytes)",
            },
          },
          {
            kind: EthereumHandlerKind.Call,
            handler: "handleMintBatchReward",
            filter: {
              function: "mintBatchReward((address[],uint256[],uint256),bytes)",
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 4261159, // This is the block that the contract was deployed on
      options: {
        abi: "ENS",
        address: "0xAD4360c87275C7De1229A8c3C0567f921c9302b1",
      },
      assets: new Map([
        [
          "ENS",
          {
            file: "./abis/ENS.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Call,
            handler: "handleCallRegistry",
            filter: {
              function: "register(address,string)",
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleENSTransfer",
            filter: {
              topics: ["Transfer(address,address,uint256)"],
            },
          },
        ],
      },
    },
  ],
};

export default project;
