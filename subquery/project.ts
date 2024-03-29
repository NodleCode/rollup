import {
  EthereumProject,
  EthereumDatasourceKind,
  EthereumHandlerKind,
} from "@subql/types-ethereum";

const project: EthereumProject = {
  specVersion: "1.0.0",
  version: "0.0.1",
  name: "Nodle-sksync-subquery",
  description: "__",
  runner: {
    node: {
      name: "@subql/node-ethereum",
      version: ">=3.0.0",
      options: {
        unsafe: true,
      }
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
    chainId: "270", // private network
    endpoint: ["https://rpc-iu435q.nodleprotocol.io"],
  },
  dataSources: [
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 1, // This is the block that the contract was deployed on
      options: {
        // Must be a key of assets
        abi: "erc721",
        // This is the contract address for wrapped ether https://explorer.zksync.io/address/0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4
        address: "0xf98633dd7a7af38a3da2c7fc34f1a7a3a14a26b9",
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
      startBlock: 1, // This is the block that the contract was deployed on
      options: {
        // Must be a key of assets
        abi: "AccessControl",
        // This is the contract address for wrapped ether https://explorer.zksync.io/address/0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4
        address: "0x27d45764490b8C4135d1EC70130163791BDE6db5",
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
