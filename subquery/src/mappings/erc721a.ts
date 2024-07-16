import assert from "assert";
import { fetchContract, fetchToken } from "../utils/erc721";
import { TransferLog } from "../types/abi-interfaces/Erc721AAbi";
import { fetchAccount, fetchMetadata } from "../utils/utils";
import { ethers } from "ethers";
import fetch from "node-fetch";

const SEPOLIA_RPC_URL =
  "https://shy-cosmopolitan-telescope.zksync-sepolia.quiknode.pro/7dca91c43e87ec74294608886badb962826e62a0/";

async function callContract(
  contractAddress: string,
  abi: any[],
  methodName: string,
  params: any[] = []
): Promise<any> {
  // Create an instance of the ethers.js Interface for encoding the data
  const iface = new ethers.utils.Interface(abi);

  // Encode the function call
  const data = iface.encodeFunctionData(methodName, params);

  // Define the JSON-RPC payload
  const payload = {
    jsonrpc: "2.0",
    method: "eth_call",
    params: [
      {
        to: contractAddress,
        data: data,
      },
      "latest",
    ],
    id: 1,
  };

  try {
    // Make the fetch call
    const response = await fetch(SEPOLIA_RPC_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    const responseData = await response.json();

    if (responseData.result) {
      // Decode the result if needed
      const decodedResult = iface.decodeFunctionResult(
        methodName,
        responseData.result
      );
      return decodedResult;
    } else {
      throw new Error(`RPC Error: ${responseData.error.message}`);
    }
  } catch (error: any) {
    throw new Error(`Fetch Error: ${error.message}`);
  }
}

const abi = [
  // Minimal ERC721 ABI with only the tokenURI method
  "function tokenURI(uint256 tokenId) view returns (string)",
];

export async function handleRewardTransfer(event: TransferLog): Promise<void> {
  assert(event.args, "No event.args");

  const contract = await fetchContract(event.address);
  if (contract) {
    const from = await fetchAccount(event.args.from);
    const to = await fetchAccount(event.args.to);
    const tokenId = event.args.tokenId;

    const token = await fetchToken(
      `${contract.id}/${tokenId}`,
      contract.id,
      tokenId.toBigInt(),
      from.id,
      ""
    );

    const tokenUri = await callContract(contract.id, abi, "tokenURI", [
      tokenId,
    ]);
    logger.info("Token URI: " + tokenUri);
    if (tokenUri) {
      const metadata = await fetchMetadata(tokenUri, [
        "nodle-community-nfts.myfilebase.com",
        "pinning.infura-ipfs.io",
        "nodle-web-wallet.infura-ipfs.io",
        "cloudflare-ipfs.com",
      ]);

      if (metadata) {
        token.content = metadata.content || metadata.image || "";
        token.name = metadata.title || metadata.name || "";
        token.description = metadata.description || "";
      }
    }

    token.ownerId = to.id;
    token.uri = String(tokenUri);
    token.transactionHash = event.transaction.hash;
    token.timestamp = event.block.timestamp * BigInt(1000);

    return token.save();
  }
}
