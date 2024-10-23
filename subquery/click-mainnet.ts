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
      startBlock: 31551522, // This is the block that the contract was deployed on
      options: {
        abi: "erc721",
        address: "0x95b3641d549f719eb5105f9550Eca4A7A2F305De",
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
        abi: "erc721",
        address: "0xe980886e4072d32784187D547F9663eFef50f58F",
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
            kind: EthereumHandlerKind.Call,
            handler: "handleApprove",
            filter: {
              function: "approve(address,uint256)",
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
        abi: "erc721",
        address: "0x6FE81f2fDE5775355962B7F3CC9b0E1c83970E15",
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
            kind: EthereumHandlerKind.Call,
            handler: "handleApprove",
            filter: {
              function: "approve(address,uint256)",
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
        abi: "erc721",
        address: "0x48e5c6f97b00Db0A4F74B1C1bc8ecd78452dDF6F",
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
            kind: EthereumHandlerKind.Call,
            handler: "handleApprove",
            filter: {
              function: "approve(address,uint256)",
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
              topics: ["Transfer(address from,address to,uint256 tokenId)"],
            },
          },
        ],
      },
    },
  ],
};

export default project;
