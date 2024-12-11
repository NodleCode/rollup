import { ethers } from "ethers";
import fetch from "node-fetch";

export const SEPOLIA_RPC_URL = "https://mainnet.era.zksync.io";

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

    console.log("checkERC20", true);
    return true;
  } catch (error) {
    console.log(error)
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
  "0xd837cFb550b7402665499f136eeE7a37D608Eb18",
  "0x9Fed2d216DBE36928613812400Fd1B812f118438",
  "0x999368030Ba79898E83EaAE0E49E89B7f6410940",
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
  "function transfer(address recipient, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transferFrom(address sender, address recipient, uint256 amount) returns (bool)",
];


const logger = console;
export const getContractDetails = async (
  address: string
): Promise<{
  symbol: string;
  name: string;
  isErc721: boolean;
  isErc20: boolean;
}> => {
  try {
    const symbol = await callContract(address, abi, "symbol");
    const name = await callContract(address, abi, "name");
    const [isErc721] = await callContract(address, abi, "supportsInterface", [
      "0x80ac58cd",
    ]).catch((error: any) => {
      return [false];
    });

    console.log("isErc721", isErc721, Array.isArray(isErc721));

    const [erc1155] = await callContract(address, abi, "supportsInterface", [
      "0xd9b67a26",
    ]).catch((error: any) => {
      return [false];
    });

    const isErc20 = isErc721 || erc1155 ? false : await checkERC20(address);

    return {
      symbol: String(symbol),
      name: String(name),
      isErc721: Boolean(isErc721 || erc1155),
      isErc20: Boolean(isErc20),
    };
  } catch (error: any) {

    return {
      symbol: "",
      name: "",
      isErc721: false,
      isErc20: false,
    };
  }
};

const main = async () => {
  const res = await getContractDetails(
    "0x80115c708E12eDd42E504c1cD52Aea96C547c05c"
  );
  console.log("res", res);
  console.log(res);
};

main();
