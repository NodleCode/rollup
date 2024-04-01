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
    endpoint: ["https://sepolia.era.zksync.dev"],
  },
  dataSources: [
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 1381030, // This is the block that the contract was deployed on
      options: {
        abi: "erc721",
        address: "0xB6844E6dC9C4E090b73c1a91e8648A3F81eD434a",
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
      startBlock: 1381033, // This is the block that the contract was deployed on
      options: {
        abi: "AccessControl",
        address: "0x94d095cfF9feef70d2b343e7f82ef7eac3a0c7A7",
      },
      assets: new Map([
        [
          "AccessControl",
          {
            file: "./abis/accesscontrol.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleRoleAdminChanged",
            filter: {
              topics: ["RoleAdminChanged(bytes32,bytes32,bytes32)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleRoleGranted",
            filter: {
              topics: ["RoleGranted(bytes32,address,address)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleRoleRevoked",
            filter: {
              topics: ["RoleRevoked(bytes32,address,address)"],
            },
          },
        ],
      },
    },
  ],
};

export default project;
