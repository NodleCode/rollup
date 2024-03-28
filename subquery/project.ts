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
      startBlock: 0, // This is the block that the contract was deployed on
      options: {
        // Must be a key of assets
        abi: "erc721",
        // This is the contract address for wrapped ether https://explorer.zksync.io/address/0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4
        address: "0xf98633DD7a7AF38A3dA2C7fc34F1a7A3A14A26b9",
      },
      assets: new Map([
        [
          "erc721",
          {
            file: "../../node_modules/@openzeppelin/contracts/build/contracts/IERC721Metadata.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleApproval",
            filter: {
              topics: [
                "Approval(indexed address,indexed address,indexed uint256)",
              ],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleApprovalForAll",
            filter: {
              topics: ["ApprovalForAll(indexed address,indexed address,bool)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleTransfer",
            filter: {
              topics: [
                "Transfer(indexed address,indexed address,indexed uint256)",
              ],
            },
          },
        ],
      },
    },
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 0, // This is the block that the contract was deployed on
      options: {
        // Must be a key of assets
        abi: "AccessControl",
        // This is the contract address for wrapped ether https://explorer.zksync.io/address/0x3355df6D4c9C3035724Fd0e3914dE96A5a83aaf4
        address: "0x6BEB7D5416b1A2bb8619e988785676c0aEdde7b8",
      },
      assets: new Map([
        [
          "AccessControl",
          {
            file: "../../node_modules/@openzeppelin/contracts/build/contracts/IAccessControl.json",
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
              topics: [
                "RoleAdminChanged(indexed bytes32,indexed bytes32,indexed bytes32)",
              ],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleRoleGranted",
            filter: {
              topics: [
                "RoleGranted(indexed bytes32,indexed address,indexed address)",
              ],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleRoleRevoked",
            filter: {
              topics: [
                "RoleRevoked(indexed bytes32,indexed address,indexed address)",
              ],
            },
          },
        ],
      },
    },
  ],
};

export default project;
