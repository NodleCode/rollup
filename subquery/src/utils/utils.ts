import { Account, Transaction } from "../types";
import fetch, { AbortError } from "node-fetch";
import AbortController from "abort-controller";

export async function fetchAccount(
  address: string,
  timestamp?: bigint
): Promise<Account> {
  let account = await Account.get(String(address).toLowerCase());

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

  const strippedCid = String(cid).replace("ipfs://", "");

  const gateway = gateways[0];
  const url = cid.startsWith("https://")
    ? cid
    : `https://${gateway}/${strippedCid}`;

  const timeout = 5000;
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeout);

  try {
    const res = await fetch(url, { signal: controller.signal as any });

    if (!res?.ok) {
      throw new Error(`HTTP error! status: ${res?.status}`);
    }

    const data = await res.json();

    return data;
  } catch (err) {
    logger.error(`Error fetching metadata for CID: ${url}`);

    const toMatch = ["Unexpected token I in JSON at position 0"];

    if ((err as any)?.name === "AbortError") {
      logger.error("Request timed out");
    }

    if (err instanceof SyntaxError && toMatch.includes(err.message)) {
      return null;
    }

    return fetchMetadata(cid, gateways.slice(1));
  } finally {
    clearTimeout(timeoutId);
  }
};
