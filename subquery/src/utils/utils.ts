import {
  Account, Transaction,
} from "../types";

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
    logger.error(`Transaction not found for hash: ${txHash}`);
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

  const strppedCid = cid.replace("ipfs://", "");

  const gateway = gateways[0];
  const url = `https://${gateway}/ipfs/${strppedCid}`;

  try {
    const res = await fetch(url);
    return await res.json();
  } catch (err) {
    logger.error(err);
    return fetchMetadata(cid, gateways.slice(1));
  }
};

