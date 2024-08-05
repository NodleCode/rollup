import { ethers } from "ethers";
import fetch from "node-fetch";

export const SEPOLIA_RPC_URL =
  "https://wandering-distinguished-tree.zksync-mainnet.quiknode.pro/20c0bc25076ea895aa263c9296c6892eba46077c/";

export async function checkERC20(address: string) {
  try {
    // Check if the contract implements the ERC-20 functions
    await callContract(address, abi, "totalSupply");
    await callContract(address, abi, "balanceOf", [
      "0x0000000000000000000000000000000000000000",
    ]);
    await callContract(address, abi, "allowance", [
      "0x0000000000000000000000000000000000000000",
      "0x0000000000000000000000000000000000000000",
    ]);

    return true;
  } catch (error) {
    logger.info(
      `Error checking ERC20 for ${address} with error ${JSON.stringify(error)}`
    );
    return false;
  }
}

export async function callContract(
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

export const nodleContracts = [
  "0x95b3641d549f719eb5105f9550eca4a7a2f305de",
  "0xd837cfb550b7402665499f136eee7a37d608eb18",
  "0x9Fed2d216DBE36928613812400Fd1B812f118438".toLowerCase(),
  "0x999368030Ba79898E83EaAE0E49E89B7f6410940".toLowerCase(),
];

export const abi = [
  // Minimal ERC721 ABI with only the tokenURI method
  "function tokenURI(uint256 tokenId) view returns (string)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function supportsInterface(bytes4 interfaceId) view returns (bool)",
  // ERC20 ABI
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "event Transfer(address indexed from, address indexed to, uint256 value)",
  "event Approval(address indexed owner, address indexed spender, uint256 value)",
];

export const erc721Abi = [
  "function tokenURI(uint256 tokenId) view returns (string)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function supportsInterface(bytes4 interfaceId) view returns (bool)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
  "event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)",
];