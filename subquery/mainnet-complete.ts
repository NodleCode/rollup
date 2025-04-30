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
    chainId: "324", // zKsync mainnet
    endpoint: [
      process.env.ZKSYNC_MAINNET_RPC!,
      "https://mainnet.era.zksync.io",
    ],
    dictionary: ["https://dict-tyk.subquery.network/query/zksync-mainnet"],
  },
  dataSources: [
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 33999048, // This is the block that the contract was deployed on
      options: {
        abi: "NODL",
        address: "0xBD4372e44c5eE654dd838304006E1f0f69983154",
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
      startBlock: 33999048,
      options: {
        abi: "NODLMigration",
        address: "0x5de7fe085ee66Fb48447e75AA8fb0598a080AEe0",
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
      startBlock: 39506626, // This is the block that the contract was deployed on
      options: {
        abi: "MigrationNFT",
        address: "0xd837cFb550b7402665499f136eeE7a37D608Eb18",
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
              topics: ["Transfer (address from, address to, uint256 tokenId)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 42332281, // This is the block that the contract was deployed on
      options: {
        abi: "Grants",
        address: "0x5855c486d2381ba41762876f18684951d5902829",
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
      startBlock: 42332281, // This is the block that the contract was deployed on
      options: {
        abi: "GrantsMigration",
        address: "0x1A89C10456A78a41B55c3aEAcfc865E079bE5690",
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
      startBlock: 44627456, // This is the block that the contract was deployed on
      options: {
        abi: "Rewards",
        address: "0xe629b208046f7a33de3a43931c9fe505a7ac3d36",
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
              function: "mintReward(tuple(address,uint256,uint256),bytes)",
            },
          },
          {
            kind: EthereumHandlerKind.Call,
            handler: "handleMintBatchReward",
            filter: {
              function:
                "mintBatchReward(tuple(address[],uint256[],uint256),bytes)",
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 31551522, // This is the block that the contract was deployed on
      options: {
        abi: "ClickContentSign",
        address: "0x95b3641d549f719eb5105f9550Eca4A7A2F305De",
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
              topics: ["Transfer(address from,address to,uint256 tokenId)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 32739526, // This is the block that the contract was deployed on
      options: {
        abi: "ClickContentSign",
        address: "0xe980886e4072d32784187D547F9663eFef50f58F",
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
              topics: ["Transfer(address from,address to,uint256 tokenId)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 32739593, // This is the block that the contract was deployed on
      options: {
        abi: "ClickContentSign",
        address: "0x6FE81f2fDE5775355962B7F3CC9b0E1c83970E15",
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
              topics: ["Transfer(address from,address to,uint256 tokenId)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 33492696, // This is the block that the contract was deployed on
      options: {
        abi: "ClickContentSign",
        address: "0x48e5c6f97b00Db0A4F74B1C1bc8ecd78452dDF6F",
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
              topics: ["Transfer(address from,address to,uint256 tokenId)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 51533910, // This is the block that the contract was deployed on
      options: {
        abi: "ENS",
        address: "0xF3271B61291C128F9dA5aB208311d8CF8E2Ba5A9",
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
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleENSTextRecord",
            filter: {
              topics: ["TextRecordSet(uint256,string,string)"],
            },
          },
        ],
      },
    },
  ],
};

export default project;
