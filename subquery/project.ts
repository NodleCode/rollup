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
      "https://shy-cosmopolitan-telescope.zksync-sepolia.quiknode.pro/7dca91c43e87ec74294608886badb962826e62a0/",
    ],
  },
  dataSources: [
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 1993364, // This is the block that the contract was deployed on
      options: {
        abi: "erc721",
        address: "0x999368030Ba79898E83EaAE0E49E89B7f6410940",
      },
      assets: new Map([
        [
          "erc721",
          {
            file: "./abis/erc721.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Call,
            handler: "handleSafeMint",
            filter: {
              function: "safeMint(address,string)",
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleApproval",
            filter: {
              topics: ["Approval(address,address,uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleApprovalForAll",
            filter: {
              topics: ["ApprovalForAll(address,address,bool)"],
            },
          },
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
        abi: "erc721",
        address: "0x195e4E251c41e8Ae9E9E961366C73e2CFbfB115A",
      },
      assets: new Map([
        [
          "erc721",
          {
            file: "./abis/erc721.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Call,
            handler: "handleSafeMint",
            filter: {
              function: "safeMint(address,string)",
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleApproval",
            filter: {
              topics: ["Approval(address,address,uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleApprovalForAll",
            filter: {
              topics: ["ApprovalForAll(address,address,bool)"],
            },
          },
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
        abi: "erc20",
        address: "0xb4B74C2BfeA877672B938E408Bae8894918fE41C",
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
      startBlock: 2157320,
      options: {
        abi: "migration",
        address: "0x1427d38B967435a3F8f476Cda0bc4F51fe66AF4D",
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
      startBlock: 3001690, // This is the block that the contract was deployed on
      options: {
        abi: "erc721-a",
        address: "0x9Fed2d216DBE36928613812400Fd1B812f118438",
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
            handler: "handleRewardTransfer",
            filter: {
              topics: ["Transfer (address from, address to, uint256 tokenId)"],
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
      startBlock: 3548120, // This is the block that the contract was deployed on
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
  ],
};

export default project;
