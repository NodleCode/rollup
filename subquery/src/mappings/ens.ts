import { NameRegisteredLog } from "./../types/abi-interfaces/ENSAbi";
import { fetchAccount } from "../utils/utils";
import { ENS } from "../types";

export async function handleNameRegistered(
  event: NameRegisteredLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const [name, owner, expires] = event.args;
  const timestamp = event.block.timestamp * BigInt(1000);
  const _expires = expires ? expires.toBigInt() * BigInt(1000) : BigInt(0);
  const _owner = await fetchAccount(owner, timestamp);
  const _name = event.args.name.toString();
  const txHash = event.transaction.hash;

  const registeredEns = new ENS(
    txHash.concat("/").concat(name),
    _owner.id,
    _expires,
    timestamp,
    _name
  );

  return registeredEns.save();
}
