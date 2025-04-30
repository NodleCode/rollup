import { Provider as L2Provider, Wallet } from "zksync-ethers";
import { Contract, JsonRpcProvider as L1Provider, parseEther } from "ethers";
import {
  ZKSYNC_DIAMOND_INTERFACE,
  NAME_SERVICE_INTERFACE,
  CLICK_RESOLVER_INTERFACE,
} from "./interfaces";
import { ZyfiSponsoredRequest } from "./types";
import admin from "firebase-admin";
import { initializeApp } from "firebase-admin/app";

import dotenv from "dotenv";

dotenv.config();

const port = process.env.PORT || 8080;
const privateKey = process.env.REGISTRAR_PRIVATE_KEY!;
const l2Provider = new L2Provider(process.env.L2_RPC_URL!);
const l2Wallet = new Wallet(privateKey, l2Provider);
const l1Provider = new L1Provider(process.env.L1_RPC_URL!);
const diamondAddress = process.env.DIAMOND_PROXY_ADDR!;

const serviceAccountKey = process.env.SERVICE_ACCOUNT_KEY!;
const serviceAccount = JSON.parse(serviceAccountKey);
initializeApp({
  credential: admin.credential.cert(serviceAccount as admin.ServiceAccount),
});

const diamondContract = new Contract(
  diamondAddress,
  ZKSYNC_DIAMOND_INTERFACE,
  l1Provider
);
const clickResolverAddress = process.env.CLICK_RESOLVER_ADDR!;
const clickResolverContract = new Contract(
  clickResolverAddress,
  CLICK_RESOLVER_INTERFACE,
  l1Provider
);
const clickNameServiceAddress = process.env.CLICK_NS_ADDR!;
const clickNameServiceContract = new Contract(
  clickNameServiceAddress,
  NAME_SERVICE_INTERFACE,
  l2Wallet
);
const nodleNameServiceAddress = process.env.NODLE_NS_ADDR!;
const nodleNameServiceContract = new Contract(
  nodleNameServiceAddress,
  NAME_SERVICE_INTERFACE,
  l2Wallet
);
const batchQueryOffset = Number(process.env.SAFE_BATCH_QUERY_OFFSET!);

const clickNSDomain = process.env.CLICK_NS_DOMAIN!;
const nodleNSDomain = process.env.NODLE_NS_DOMAIN!;
const parentTLD = process.env.PARENT_TLD!;
const zyfiSponsoredUrl = process.env.ZYFI_BASE_URL
  ? new URL(process.env.ZYFI_SPONSORED!, process.env.ZYFI_BASE_URL)
  : null;

const zyfiRequestTemplate: ZyfiSponsoredRequest = {
  chainId: Number(process.env.L2_CHAIN_ID!),
  feeTokenAddress: process.env.FEE_TOKEN_ADDR!,
  gasLimit: process.env.GAS_LIMIT!,
  isTestnet: process.env.L2_CHAIN_ID === "300",
  checkNft: false,
  txData: {
    from: l2Wallet.address,
    to: clickNameServiceAddress,
    data: "0x0",
    value: "0",
  },
  sponsorshipRatio: 100,
  replayLimit: 5,
};

const nameServiceContracts = {
  [clickNSDomain]: clickNameServiceAddress,
  [nodleNSDomain]: nodleNameServiceAddress,
};

const buildZyfiRegisterRequest = (
  owner: string,
  name: string,
  subdomain: keyof typeof nameServiceContracts
) => {
  const encodedRegister = NAME_SERVICE_INTERFACE.encodeFunctionData(
    "register",
    [owner, name]
  );

  const zyfiRequest: ZyfiSponsoredRequest = {
    ...zyfiRequestTemplate,
    txData: {
      ...zyfiRequestTemplate.txData,
      data: encodedRegister,
      to: nameServiceContracts[subdomain],
    },
  };

  return zyfiRequest;
};

const buildZyfiSetTextRecordRequest = (
  name: string,
  subdomain: keyof typeof nameServiceContracts,
  key: string,
  value: string
) => {
  const encodedSetTextRecord = NAME_SERVICE_INTERFACE.encodeFunctionData(
    "setTextRecord",
    [name, key, value]
  );

  const zyfiRequest: ZyfiSponsoredRequest = {
    ...zyfiRequestTemplate,
    txData: {
      ...zyfiRequestTemplate.txData,
      data: encodedSetTextRecord,
      to: nameServiceContracts[subdomain],
    },
  };

  return zyfiRequest;
};

const nameServiceAddresses = {
  [clickNSDomain]: clickNameServiceAddress,
  [nodleNSDomain]: nodleNameServiceAddress,
};

export {
  port,
  l1Provider,
  l2Provider,
  l2Wallet,
  diamondAddress,
  diamondContract,
  clickResolverContract,
  clickNameServiceAddress,
  clickNameServiceContract,
  nodleNameServiceAddress,
  nodleNameServiceContract,
  batchQueryOffset,
  clickNSDomain,
  nodleNSDomain,
  parentTLD,
  zyfiSponsoredUrl,
  zyfiRequestTemplate,
  buildZyfiRegisterRequest,
  buildZyfiSetTextRecordRequest,
  nameServiceAddresses,
};
