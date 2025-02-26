import { ethers } from "ethers";
import fetch from "node-fetch";

export const RPC_URL = "https://sepolia.era.zksync.dev";

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
    return false;
  }
}

export async function callContract(
  contractAddress: string,
  abi: any[],
  methodName: string,
  params: any[] = [],
  block: string = "latest"
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
      block,
    ],
    id: 1,
  };

  try {
    // Make the fetch call
    const response = await fetch(RPC_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    const responseData = await response.json();

    if (responseData !== null && typeof responseData === 'object') {
      if ('result' in responseData && responseData.result !== null) {
        if (ethers.utils.isBytesLike(responseData.result)) {
          return iface.decodeFunctionResult(
            methodName,
            responseData.result
          );
        }
        else {
          return responseData.result;
        }
      }
      if ('error' in responseData && responseData.error !== null) {
        if (typeof responseData.error === 'object' && 'message' in responseData.error && responseData.error.message != null) {
          throw new Error(`RPC Error: ${responseData.error.message}`);
        }
        else {
          throw new Error(`RPC Error: ${responseData.error}`);
        }
      }
    }

  } catch (error: any) {
    throw new Error(`Fetch Error: ${error.message}`);
  }
}

export const nodleContracts = [
  "0x95b3641d549f719eb5105f9550eca4a7a2f305de",
  "0xd837cFb550b7402665499f136eeE7a37D608Eb18",
  "0x9Fed2d216DBE36928613812400Fd1B812f118438",
  "0x999368030Ba79898E83EaAE0E49E89B7f6410940",
  "0x6FE81f2fDE5775355962B7F3CC9b0E1c83970E15", // vivendi
].map((address) => address.toLowerCase());

export const contractForSnapshot = [
  "0x95b3641d549f719eb5105f9550eca4a7a2f305de",
].map((address) => address.toLowerCase());

export const abi = [
  // Minimal ERC721 ABI with only the tokenURI method
  "function tokenURI(uint256 tokenId) view returns (string)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function supportsInterface(bytes4 interfaceId) view returns (bool)",
  // ERC20 ABI
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function transfer(address recipient, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transferFrom(address sender, address recipient, uint256 amount) returns (bool)",
];
