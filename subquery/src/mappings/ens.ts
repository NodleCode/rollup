import { NameRegisteredLog } from './../types/abi-interfaces/ENSAbi';
import { fetchAccount } from '../utils/utils';
import { ENS } from '../types';

export async function handleNameRegistered(event: NameRegisteredLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  const timestamp = event.block.timestamp * BigInt(1000);
  const expiresAt =
    event.args.expires ? event.args.expires.toBigInt() * BigInt(1000) : BigInt(0);
  const owner = await fetchAccount(event.args.owner, timestamp);
  const name = event.args.name.toString();
  const txHash = event.transaction.hash;

  const registeredEns = new ENS(
    txHash.concat("/").concat(name),
    owner.id,
    expiresAt,
    timestamp,
    name
  );
  
  return registeredEns.save();
}
