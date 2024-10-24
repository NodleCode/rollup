import { Account, Transaction } from "../types";
import fetch from "node-fetch";

export async function fetchAccount(
  address: string,
  timestamp?: bigint
): Promise<Account> {
  let account = await Account.get(address);

  if (!account) {
    account = new Account(address);
    account.timestamp = timestamp || BigInt(0);
    account.balance = BigInt(0);
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
    logger.error(`Transaction not found for hash: ${txHash}`);
    const newTx = new Transaction(txHash, timestamp, blocknumber);
    newTx.save();

    return newTx;
  }

  return tx;
};

export const isValidTokenUri = (uri: string): boolean => {
  const isCid = uri.startsWith("ipfs://");
  return isCid || uri.startsWith("https://");
};

export const fetchMetadata = async (
  cid: string,
  gateways: string[]
): Promise<any> => {
  if (gateways.length === 0 || !isValidTokenUri(String(cid))) {
    return null;
  }

  const strppedCid = String(cid).replace("ipfs://", "");

  const gateway = gateways[0];
  const url = cid.startsWith("https://")
    ? cid
    : `https://${gateway}/${strppedCid}`;

  try {
    const res = await fetch(url);
    return await res.json();
  } catch (err) {
    logger.error(err);
    const toMatch = ["Unexpected token I in JSON at position 0"];

    if (err instanceof SyntaxError && toMatch.includes(err.message)) {
      return null;
    }

    return fetchMetadata(cid, gateways.slice(1));
  }
};
