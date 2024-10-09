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
      "https://wandering-distinguished-tree.zksync-mainnet.quiknode.pro/20c0bc25076ea895aa263c9296c6892eba46077c/",
      "https://mainnet.era.zksync.io",
    ],
  },
  dataSources: [
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 33999048, // This is the block that the contract was deployed on
      options: {
        abi: "erc20",
        address: "0xBD4372e44c5eE654dd838304006E1f0f69983154",
      },
      assets: new Map([
        [
          "erc20",
          {
            file: "./abis/erc20.abi.json",
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
        abi: "migration",
        address: "0x5de7fe085ee66Fb48447e75AA8fb0598a080AEe0",
      },
      assets: new Map([
        [
          "migration",
          {
            file: "./abis/migration.abi.json",
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
        abi: "erc721-a",
        address: "0xd837cFb550b7402665499f136eeE7a37D608Eb18",
      },
      assets: new Map([
        [
          "erc721-a",
          {
            file: "./abis/erc721-a.abi.json",
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
        abi: "grants",
        address: "0xdAdF329E8b30D878b139074De163D3A591aAB394",
      },
      assets: new Map([
        [
          "grants",
          {
            file: "./abis/grants.abi.json",
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
              topics: ["Claimed(address, uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleRenounced",
            filter: {
              topics: ["Renounced(address, address)"],
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
              topics: ["VestingSchedulesCanceled(address, address)"],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 42332281, // This is the block that the contract was deployed on
      options: {
        abi: "grantsMigration",
        address: "0xF81b3b954221BeDcf762cd18FEc1A22D25016B2E",
      },
      assets: new Map([
        [
          "grantsMigration",
          {
            file: "./abis/grantsMigration.abi.json",
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
        abi: "rewards",
        address: "0xe629b208046f7a33de3a43931c9fe505a7ac3d36",
      },
      assets: new Map([
        [
          "rewards",
          {
            file: "./abis/rewards.abi.json",
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
  ],
};

export default project;
