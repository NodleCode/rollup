import { Provider as L2Provider, Wallet } from "zksync-ethers";
import { Contract, JsonRpcProvider as L1Provider, parseEther } from "ethers";
import {
  ZKSYNC_DIAMOND_INTERFACE,
  CLICK_NAME_SERVICE_INTERFACE,
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
const diamondContract = new Contract(
  diamondAddress,
  ZKSYNC_DIAMOND_INTERFACE,
  l1Provider,
);
const clickResolverAddress = process.env.CLICK_RESOLVER_ADDR!;
const clickResolverContract = new Contract(
  clickResolverAddress,
  CLICK_RESOLVER_INTERFACE,
  l1Provider,
);
const clickNameServiceAddress = process.env.CNS_ADDR!;
const clickNameServiceContract = new Contract(
  clickNameServiceAddress,
  CLICK_NAME_SERVICE_INTERFACE,
  l2Wallet,
);
const batchQueryOffset = Number(process.env.SAFE_BATCH_QUERY_OFFSET!);
const serviceAccountKey = process.env.SERVICE_ACCOUNT_KEY!;
const serviceAccount = JSON.parse(serviceAccountKey);
const firebaseApp = initializeApp({
  credential: admin.credential.cert(serviceAccount as admin.ServiceAccount),
});
const cnsDomain = process.env.CNS_DOMAIN!;
const cnsTld = process.env.CNS_TLD!;
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
  batchQueryOffset,
  cnsDomain,
  cnsTld,
  zyfiSponsoredUrl,
  zyfiRequestTemplate,
};
