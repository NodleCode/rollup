import { RegisterTransaction, TransferLog } from "./../types/abi-interfaces/ENSAbi";
import { fetchAccount, fetchTransaction } from "../utils/utils";
import { ENS } from "../types";
import { fetchContract } from "../utils/erc721";
import { ethers } from "ethers";

function generateId(name: string) {
  const hash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(name));
  const uint256 = ethers.BigNumber.from(hash).toString();
  return uint256;
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

export async function handleENSTransfer(event: TransferLog) {
  const [from, to, tokenId] = event.args!;
  const txHash = event.transactionHash;
  const idx = event.transactionIndex;

  const timestamp = event.block.timestamp * BigInt(1000);
  const _from = await fetchAccount(from, timestamp);
  const _to = await fetchAccount(to, timestamp);
  const txIndex = event.transactionIndex;

  const contract = await fetchContract(event.address);

  const transfer = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  const fromENSs = await ENS.getByOwnerId(_from.id, {
    limit: 1000,
    orderBy: "registeredAt",
    orderDirection: "DESC",
  });

  const fromENS = fromENSs.find((ens) => generateId(ens.name) === tokenId.toString());

  if (fromENS && fromENS.ownerId !== _to.id) {
    const ENSEntity = fromENS;

    ENSEntity.ownerId = _to.id;
    const restFromENSs = fromENSs.filter((ens) => ens.id !== fromENS.id);

    // set name to the remaining last registered ens name
    _from.name = restFromENSs.length > 0 ? restFromENSs[0].name : "";
    _to.name = _to.name ? _to.name : fromENS.name;

    await ENSEntity.save();
  }

  return Promise.all([_to.save(), _from.save(), transfer.save(), contract.save()]);
}
