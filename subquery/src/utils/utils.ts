import { Account, Transaction } from "../types";
import fetch from "node-fetch";
import { abi, callContract, checkERC20 } from "./const";

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
      logger.info(`Error calling supportsInterface for ${address}`);
      logger.info(JSON.stringify(error));
      return [false];
    });

    const [erc1155] = await callContract(address, abi, "supportsInterface", [
      "0xd9b67a26",
    ]).catch((error: any) => {
      logger.info(`Error calling supportsInterface for ${address}`);
      logger.info(JSON.stringify(error));
      return [false];
    });

    logger.info(`isErc721: ${isErc721}`);
    const isErc20 = isErc721 || erc1155 ? false : await checkERC20(address);

    return {
      symbol: String(symbol),
      name: String(name),
      isErc721: Boolean(isErc721 || erc1155),
      isErc20: Boolean(isErc20),
    };
  } catch (error: any) {
    logger.info(`Error getting contract details for ${address}`);
    logger.info(JSON.stringify(error));

    return {
      symbol: "",
      name: "",
      isErc721: false,
      isErc20: false,
    };
  }
};

export async function fetchAccount(address: string): Promise<Account> {
  let account = await Account.get(address);

  if (!account) {
    account = new Account(address);
    account.save();
  }

  return account;
}

export const fetchTransaction = async (
  txHash: string,
  timestamp: bigint,
  blocknumber: bigint
): Promise<Transaction> => {
  const tx = await Transaction.get(txHash);

  if (!tx) {
    logger.info(`Transaction not found for hash: ${txHash}`);
    const newTx = new Transaction(txHash, timestamp, blocknumber);
    newTx.save();

    return newTx;
  }

  return tx;
};

export const fetchMetadata = async (
  cid: string,
  gateways: string[]
): Promise<any> => {
  if (gateways.length === 0) {
    return null;
  }
  logger.info(`Fetching metadata for CID: ${cid}`);
  const strppedCid = String(cid).replace("ipfs://", "");

  const gateway = gateways[0];
  const url = `https://${gateway}/ipfs/${strppedCid}`;

  try {
    const res = await fetch(url);
    return await res.json();
  } catch (err) {
    logger.info(err);
    const toMatch = ["Unexpected token I in JSON at position 0"];

    if (err instanceof SyntaxError && toMatch.includes(err.message)) {
      return null;
    }

    return fetchMetadata(cid, gateways.slice(1));
  }
};
