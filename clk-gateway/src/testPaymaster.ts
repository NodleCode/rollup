// Env example: to be set in the .env file
/*
REGISTRAR_PRIVATE_KEY=your-eth-private-key
L2_RPC_URL=https://sepolia.era.zksync.dev
PAYMASTER_TEST_ADDR=0x76f03aD8AA376385e45221d45371DeB51D597c43
L2_CHAIN_ID=300
ZYFI_BASE_URL=https://api.zyfi.org/api/
ZYFI_SPONSORED=erc20_sponsored_paymaster/v1
ZYFI_API_KEY=your-zyfi-api-key
FEE_TOKEN_ADDR=0xb4B74C2BfeA877672B938E408Bae8894918fE41C
GAS_LIMIT=1000000
*/
// Usage example: source .env && npx ts-node src/testPaymaster.ts 0x2E7F3926Ae74FDCDcAde2c2AB50990C5daFD42bD alex

import { Interface, getAddress, Contract } from "ethers";
import { Provider as L2Provider, Wallet } from "zksync-ethers";

// L2 Contract
export const PAYMASTER_TEST_INTERFACE = new Interface([
  "function register(address to, string memory name)",
]);

import dotenv from "dotenv";
dotenv.config();

const to: string = getAddress(process.argv[2]);
const name: string = process.argv[3];
const privateKey = process.env.REGISTRAR_PRIVATE_KEY!;
const l2Provider = new L2Provider(process.env.L2_RPC_URL!);
const l2Wallet = new Wallet(privateKey, l2Provider);
const paymasterTestAddress = getAddress(process.env.PAYMASTER_TEST_ADDR!);

const paymasterTestContract = new Contract(
  paymasterTestAddress,
  PAYMASTER_TEST_INTERFACE,
  l2Wallet,
);
const zyfiSponsoredUrl = process.env.ZYFI_BASE_URL
  ? new URL(process.env.ZYFI_SPONSORED!, process.env.ZYFI_BASE_URL)
  : null;

type ZyfiSponsoredRequest = {
  chainId: number;
  feeTokenAddress: string;
  gasLimit: string;
  isTestnet: boolean;
  checkNft: boolean;
  txData: {
    from: string;
    to: string;
    value: string;
    data: string;
  };
  sponsorshipRatio: number;
  replayLimit: number;
};

interface ZyfiSponsoredResponse {
  txData: {
    chainId: number;
    from: string;
    to: string;
    value: string;
    data: string;
    customData: {
      paymasterParams: {
        paymaster: string;
        paymasterInput: string;
      };
      gasPerPubdata: number;
    };
    maxFeePerGas: string;
    gasLimit: number;
  };
  gasLimit: string;
  gasPrice: string;
  tokenAddress: string;
  tokenPrice: string;
  feeTokenAmount: string;
  feeTokenDecimals: string;
  feeUSD: string;
  markup: string;
  expirationTime: string;
  expiresIn: string;
  maxNonce: string;
  protocolAddress: string;
  sponsorshipRatio: string;
  warnings: string[];
}

async function fetchZyfiSponsored(
  request: ZyfiSponsoredRequest,
): Promise<ZyfiSponsoredResponse> {
  console.log(`zyfiSponsoredUrl: ${zyfiSponsoredUrl}`);
  const response = await fetch(zyfiSponsoredUrl!, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-KEY": process.env.ZYFI_API_KEY!,
    },
    body: JSON.stringify(request),
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch zyfi sponsored`);
  }
  const sponsoredResponse = (await response.json()) as ZyfiSponsoredResponse;

  return sponsoredResponse;
}

const zyfiRequestTemplate: ZyfiSponsoredRequest = {
  chainId: Number(process.env.L2_CHAIN_ID!),
  feeTokenAddress: process.env.FEE_TOKEN_ADDR!,
  gasLimit: process.env.GAS_LIMIT!,
  isTestnet: process.env.L2_CHAIN_ID === "300",
  checkNft: false,
  txData: {
    from: l2Wallet.address,
    to: paymasterTestAddress,
    data: "0x0",
    value: "0",
  },
  sponsorshipRatio: 100,
  replayLimit: 5,
};

async function main(to: string, name: string): Promise<void> {
  let response;
  if (zyfiSponsoredUrl) {
    const encodedRegister = PAYMASTER_TEST_INTERFACE.encodeFunctionData(
      "register",
      [to, name],
    );
    const zyfiRequest: ZyfiSponsoredRequest = {
      ...zyfiRequestTemplate,
      txData: {
        ...zyfiRequestTemplate.txData,
        data: encodedRegister,
      },
    };
    const zyfiResponse = await fetchZyfiSponsored(zyfiRequest);
    console.log(`ZyFi response: ${JSON.stringify(zyfiResponse)}`);

    response = await l2Wallet.sendTransaction(zyfiResponse.txData);
  } else {
    response = await paymasterTestContract.register(to, name);
  }

  const receipt = await response.wait();
  if (receipt.status !== 1) {
    throw new Error("Transaction failed");
  }
  console.log(`Transaction hash: ${receipt.hash}`);
}

main(to, name);
