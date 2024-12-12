import { RegisterTransaction } from "./../types/abi-interfaces/ENSAbi";
import { fetchAccount } from "../utils/utils";
import { ENS } from "../types";

export async function handleCallRegistry(tx: RegisterTransaction) {
  const receipt = await tx.receipt();

  if (!receipt.status) {
    return;
  }

  if (!tx.args || !tx.logs) {
    throw new Error("No tx.args or tx.logs");
  }

  const [owner, name] = tx.args;
  const txHash = tx.hash;
  const idx = tx.logs.findIndex(
    (log) =>
    {
      return (
        log.transactionHash === txHash &&
        !!log.args &&
        log.args[0] !== "0x0000000000000000000000000000000000000000" &&
        log.args[1] === owner
      );
    }
  );

  const timestamp = BigInt(tx.blockTimestamp) * BigInt(1000);
  const _owner = await fetchAccount(owner, timestamp);
  const caller = await fetchAccount(String(tx.from).toLowerCase(), timestamp);
  const txIndex = tx.transactionIndex;

  const event = tx.logs[idx];

  const [rawOwner, _, expires] = event.args!;

  const _expires = expires ? expires.toBigInt() * BigInt(1000) : BigInt(0);
  const _name = JSON.stringify(rawOwner);
  const registeredEns = new ENS(
    txHash.concat("/").concat(txIndex.toString()),
    _owner.id,
    timestamp,
    name,
    caller.id
  );

  registeredEns.expiresAt = _expires;
  registeredEns.rawName = _name;
  _owner.name = name;

  return Promise.all([registeredEns.save(), _owner.save()]);
}
