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
        [
          "erc721-a",
          {
            file: "./abis/erc721-a.abi.json",
          },
        ],
        [
          "erc20",
          {
            file: "./abis/erc20.abi.json",
          },
        ],
        [
          "migration",
          {
            file: "./abis/migration.abi.json",
          },
        ],
        [
          "grants",
          {
            file: "./abis/grants.abi.json",
          },
        ],
        [
          "grantsMigration",
          {
            file: "./abis/grantsMigration.abi.json",
          },
        ],
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
            handler: "handleSafeMint",
            filter: {
              function: "safeMint(address,string)",
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
  ],
};

export default project;
