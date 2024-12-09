import { NameRegisteredLog, RegisterTransaction } from "./../types/abi-interfaces/ENSAbi";
import { fetchAccount } from "../utils/utils";
import { ENS } from "../types";

export async function handleNameRegistered(
  event: NameRegisteredLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const txHash = event.transaction.hash;
  const [name, owner, expires] = event.args;
  const timestamp = event.block.timestamp * BigInt(1000);
  const _expires = expires ? expires.toBigInt() * BigInt(1000) : BigInt(0);
  const _name = name;

  const registeredEns = await ENS.get(
    txHash.concat("/").concat(event.logIndex.toString())
  )

  if (registeredEns) {
    registeredEns.expiresAt = _expires;
    registeredEns.rawName = JSON.stringify(_name);
    return registeredEns.save();
  } else  {
    throw new Error("No registeredEns");
  }
}

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
  const idx = tx.logs.findIndex((log) => log.transactionHash === txHash);
  const timestamp = BigInt(tx.blockTimestamp) * BigInt(1000);
  const _owner = await fetchAccount(owner, timestamp);
  const caller = await fetchAccount(String(tx.from).toLowerCase(), timestamp);


  const registeredEns = new ENS(
    txHash.concat("/").concat(idx.toString()),
    _owner.id,
    timestamp,
    name,
    caller.id
  );

  return registeredEns.save();
  
}