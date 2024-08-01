import { EthereumBlock } from "@subql/types-ethereum";
import { NativeTransaction } from "../types";
import { fetchAccount } from "../utils/utils";

export const handleNativeTransfers = async (
  block: EthereumBlock
): Promise<void> => {
  const transactions = block.transactions;
  const toSave = [];
  for (const tx of transactions) {
    if (tx.to) {
      const from = await fetchAccount(tx.from);
      const to = await fetchAccount(tx.to);
      const hash = tx.hash;
      const transfer = new NativeTransaction(
        tx.hash.concat("/").concat(`${tx.transactionIndex}`),
        block.timestamp * BigInt(1000),
        BigInt(block.number),
        from.id,
        tx.value,
        tx.gas,
        tx.gasPrice,
        tx.nonce
      );
      transfer.hash = hash;
      transfer.toId = to.id;

      toSave.push(transfer);
    }
  }

  await store.bulkCreate("NativeTransaction", toSave);
};
