require("dotenv").config();
import {
  EthereumProject,
  EthereumDatasourceKind,
  EthereumHandlerKind,
} from "@subql/types-ethereum";

const project: EthereumProject = {
  specVersion: "1.0.0",
  version: "0.0.1",
  name: "Nodle-zksync-l2-bridge",
  description: "L2 Bridge indexing for NODL token bridge",
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
    chainId: "324", // zkSync Mainnet
    endpoint: ["https://mainnet.era.zksync.io"],
    dictionary: ["https://dict-tyk.subquery.network/query/zksync-mainnet"],
  },
  dataSources: [
    {
      kind: EthereumDatasourceKind.Runtime,
      startBlock: 65260492,
      options: {
        abi: "BridgeL2",
        address: "0x2c1B65dA72d5Cf19b41dE6eDcCFB7DD83d1B529E",
      },
      assets: new Map([
        [
          "BridgeL2",
          {
            file: "./abis/BridgeL2.abi.json",
          },
        ],
      ]),
      mapping: {
        file: "./dist/index.js",
        handlers: [
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleDepositFinalized",
            filter: {
              topics: ["DepositFinalized(address,address,uint256)"],
            },
          },
          {
            kind: EthereumHandlerKind.Event,
            handler: "handleWithdrawalInitiated",
            filter: {
              topics: ["WithdrawalInitiated(address,address,uint256)"],
            },
          },
        ],
      },
    },
  ],
};

export default project;

