import { Account, Transaction } from "../types";

export async function fetchAccount(
  address: string,
  timestamp?: bigint
): Promise<Account> {
  const lowercaseAddress = String(address).toLowerCase();
  let account = await Account.get(lowercaseAddress);

  if (!account) {
    account = new Account(lowercaseAddress);
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
    const newTx = new Transaction(txHash, timestamp, blocknumber);
    newTx.save();

    return newTx;
  }

  return tx;
};
