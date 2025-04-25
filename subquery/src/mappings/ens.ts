import {
  RegisterTransaction,
  TextRecordSetLog,
  TransferLog,
} from "./../types/abi-interfaces/ENSAbi";
import { fetchAccount, fetchTransaction } from "../utils/utils";
import { ENS, TextRecord } from "../types";
import { fetchContract } from "../utils/erc721";
import { ethers } from "ethers";

if (!process.env.CLICK_NS_ADDR || !process.env.NODLE_NS_ADDR) {
  throw new Error("CLICK_NS_ADDR or NODLE_NS_ADDR is not set");
}

function generateId(name: string) {
  const hash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(name));
  const uint256 = ethers.BigNumber.from(hash).toString();
  return uint256;
}

function getDomain(contract: string) {
  const nodlContract = String(process.env.CLICK_NS_ADDR);
  const clkContract = String(process.env.NODLE_NS_ADDR);

  const map = {
    [nodlContract]: "nodl.eth",
    [clkContract]: "clk.eth",
  };

  return map[contract];
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
  const idx = tx.logs.findIndex((log) => {
    return (
      log.transactionHash === txHash &&
      !!log.args &&
      log.args[0] !== "0x0000000000000000000000000000000000000000" &&
      log.args[1] === owner
    );
  });

  const domain = getDomain(tx.to!);
  const timestamp = BigInt(tx.blockTimestamp) * BigInt(1000);
  const ownerAccount = await fetchAccount(owner, timestamp);
  const caller = await fetchAccount(String(tx.from).toLowerCase(), timestamp);

  const event = tx.logs[idx];

  const [,, expires] = event.args!;

  const expiresAt = expires ? expires.toBigInt() * BigInt(1000) : BigInt(0);

  const registeredEns = new ENS(
    generateId(name),
    ownerAccount.id,
    timestamp,
    name,
    `${name}.${domain}`,
    tx.to!,
    domain,
    caller.id
  );

  registeredEns.expiresAt = expiresAt;
  registeredEns.rawName = '';
  ownerAccount.name = name;
  ownerAccount.primaryName = `${name}.${domain}`;

  return Promise.all([registeredEns.save(), ownerAccount.save()]);
}

const getENSPaginated = async (
  ownerId: string,
  offset: number = 0,
  limit: number = 100
): Promise<ENS[]> => {
  const ens = await ENS.getByOwnerId(ownerId, {
    limit,
    offset,
    orderBy: "registeredAt",
    orderDirection: "DESC",
  });

  if (ens.length === 0) {
    return [];
  }

  if (ens.length === limit) {
    return [...ens, ...(await getENSPaginated(ownerId, offset + limit, limit))];
  }

  return ens;
};

export async function handleENSTextRecord(event: TextRecordSetLog) {
  const [tokenId, key, value] = event.args!;
  const ens = await ENS.get(tokenId.toString());
  if (ens) {
    const textRecordId = `${ens.id}-${key}`;
    let textRecord = await TextRecord.get(textRecordId);

    if (!textRecord) {
      textRecord = new TextRecord(
        textRecordId,
        ens.id,
        key,
        value
      );
    }

    textRecord.value = value;

    return textRecord.save();
  }
}

export async function handleENSTransfer(event: TransferLog) {
  const [from, to, tokenId] = event.args!;
  const txHash = event.transactionHash;
  const idx = event.transactionIndex;

  const timestamp = event.block.timestamp * BigInt(1000);
  const fromAccount = await fetchAccount(from, timestamp);
  const toAccount = await fetchAccount(to, timestamp);
  const txIndex = event.transactionIndex;

  const contract = await fetchContract(event.address);

  const transfer = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  const fromENSs = await getENSPaginated(fromAccount.id);

  const fromENS = fromENSs.find(
    (ens) => generateId(ens.name) === tokenId.toString()
  );

  if (fromENS && fromENS.ownerId !== toAccount.id) {
    const ENSEntity = fromENS;

    ENSEntity.ownerId = toAccount.id;
    const restFromENSs = fromENSs.filter((ens) => ens.id !== fromENS.id);

    // set name to the remaining last registered ens name
    fromAccount.name = restFromENSs.length > 0 ? restFromENSs[0].name : "";
    toAccount.name = toAccount.name ? toAccount.name : fromENS.name;

    await ENSEntity.save();
  }

  return Promise.all([
    toAccount.save(),
    fromAccount.save(),
    transfer.save(),
    contract.save(),
  ]);
}
