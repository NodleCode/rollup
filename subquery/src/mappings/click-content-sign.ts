import assert from "assert";
import {
  fetchContract,
  fetchToken,
  getApprovalLog,
} from "../utils/erc721";
import {
  TransferLog,
  SafeMintTransaction,
} from "../types/abi-interfaces/ClickContentSignAbi";
import { fetchAccount, fetchMetadata, fetchTransaction } from "../utils/utils";
import { abi, callContract, contractForSnapshot, nodleContracts } from "../utils/const";
import { ERC721Transfer, TokenSnapshot, TokenSnapshotV2 } from "../types";

const keysMapping = {
  application: "Application",
  channel: "Channel",
  contentType: "Content Type",
  duration: "Duration (sec)",
  captureDate: "Capture date",
  longitude: "Longitude",
  latitude: "Latitude",
  locationPrecision: "Location Precision",
};

function convertArrayToObject(arr: any[]) {
  // validate array
  if (!Array.isArray(arr)) return null;

  return arr.reduce((acc, { trait_type, value }) => {
    acc[trait_type] = value;
    return acc;
  }, {});
}

export async function handleTransfer(event: TransferLog): Promise<void> {
  logger.error("Handling transfer event");
  assert(event.args, "No event.args");
  logger.info(`Handling transfer event: ${event.transaction.hash}`);
  const contract = await fetchContract(event.address);
  if (contract) {
    const timestamp = event.block.timestamp * BigInt(1000);
    const from = await fetchAccount(event.args[0], timestamp);
    const to = await fetchAccount(event.args[1], timestamp);
    const tokenId = event.args[2];

    const transferTx = await fetchTransaction(
      event.transaction.hash,
      timestamp,
      BigInt(event.block.number)
    );

    const token = await fetchToken(
      `${contract.id}/${tokenId}`,
      contract.id,
      BigInt(tokenId as any),
      from.id,
      ""
    );

    if (!token.uri) {
      const tokenUri = await callContract(contract.id, abi, "tokenURI", [
        tokenId,
      ]).catch((error) => {
        return null;
      });

      if (tokenUri && nodleContracts.includes(contract.id)) {
        const metadata = await fetchMetadata(String(tokenUri), [
          "nodle-community-nfts.myfilebase.com/ipfs",
          "storage.googleapis.com/ipfs-backups",
        ]);

        if (metadata) {
          token.content = metadata.content || metadata.image || "";
          token.channel = metadata.channel || "";
          token.contentType = metadata.contentType || "";
          token.thumbnail = metadata.thumbnail || "";
          token.name = metadata.name || "";
          token.description = metadata.description || "";
          token.contentHash = metadata.content_hash || "";

          // new metadata from attributes
          if (metadata.attributes && metadata.attributes?.length > 0) {
            const objectAttributes = convertArrayToObject(metadata.attributes);

            if (objectAttributes) {
              token.application = objectAttributes[keysMapping.application];
              token.channel = objectAttributes[keysMapping.channel];
              token.contentType = objectAttributes[keysMapping.contentType];
              token.duration = objectAttributes[keysMapping.duration] || 0;
              token.captureDate = objectAttributes[keysMapping.captureDate]
                ? BigInt(objectAttributes[keysMapping.captureDate])
                : BigInt(0);
              token.longitude = objectAttributes[keysMapping.longitude]
                ? parseFloat(objectAttributes[keysMapping.longitude])
                : 0;
              token.latitude = objectAttributes[keysMapping.latitude]
                ? parseFloat(objectAttributes[keysMapping.latitude])
                : 0;
              token.locationPrecision =
                objectAttributes[keysMapping.locationPrecision];
            }
          }
        }
      }
      token.uri = String(tokenUri);
    }

    const transfer = new ERC721Transfer(
      `${contract.id}/${token.id}`,
      from.id,
      transferTx.id,
      event.block.timestamp * BigInt(1000),
      contract.id,
      token.id,
      from.id,
      to.id
    );

    token.ownerId = to.id;
    token.transactionHash = event.transaction.hash;
    token.timestamp = event.block.timestamp * BigInt(1000);

    await Promise.all([token.save(), transfer.save()]);
  }
}

export async function handleSafeMint(tx: SafeMintTransaction) {
  const receipt = await tx.receipt();

  if (!receipt.status) {
    // skip failed transactions
    return;
  }

  if (!tx.args || !tx.logs) {
    throw new Error("No tx.args or tx.logs");
  }

  // Call to the contract
  const contract = await fetchContract(String(tx.to).toLowerCase());

  const safeMintTx = await fetchTransaction(
    tx.hash,
    tx.blockTimestamp * BigInt(1000),
    BigInt(tx.blockNumber)
  );

  // Caller
  const timestamp = BigInt(tx.blockTimestamp) * BigInt(1000);
  const caller = await fetchAccount(String(tx.from).toLowerCase(), timestamp);

  const owner = await fetchAccount(
    String(await tx.args[0]).toLowerCase(),
    timestamp
  );
  const uri = await tx.args[1];

  const tokenId = getApprovalLog(tx.logs, await tx.args[0])![2].toBigInt();

  const token = await fetchToken(
    `${contract.id}/${tokenId}`,
    contract.id,
    tokenId,
    owner.id,
    caller.id
  );

  token.timestamp = timestamp;

  token.transactionHash = tx.hash;

  token.uri = uri;

  if (nodleContracts.includes(contract.id)) {
    const metadata = await fetchMetadata(uri, [
      "nodle-community-nfts.myfilebase.com/ipfs",
      "storage.googleapis.com/ipfs-backups",
    ]);

    if (metadata) {
      token.content = metadata.content || metadata.image || "";
      token.channel = metadata.channel || "";
      token.contentType = metadata.contentType || "";
      token.thumbnail = metadata.thumbnail || "";
      token.name = metadata.name || "";
      token.description = metadata.description || "";
      token.contentHash = metadata.content_hash || "";

      // new metadata from attributes
      if (metadata.attributes && metadata.attributes?.length > 0) {
        const objectAttributes = convertArrayToObject(metadata.attributes);

        if (objectAttributes) {
          token.application = objectAttributes[keysMapping.application];
          token.channel = objectAttributes[keysMapping.channel];
          token.contentType = objectAttributes[keysMapping.contentType];
          token.duration = objectAttributes[keysMapping.duration] || 0;
          token.captureDate = objectAttributes[keysMapping.captureDate]
            ? BigInt(objectAttributes[keysMapping.captureDate])
            : BigInt(0);
          token.longitude = objectAttributes[keysMapping.longitude]
            ? parseFloat(objectAttributes[keysMapping.longitude])
            : 0;
          token.latitude = objectAttributes[keysMapping.latitude]
            ? parseFloat(objectAttributes[keysMapping.latitude])
            : 0;
          token.locationPrecision =
            objectAttributes[keysMapping.locationPrecision];
        }
      }
    }
  }

  const toSave = [contract, safeMintTx, caller, owner, token];

  if (contractForSnapshot.includes(contract.id)) {
    let snapshot = await TokenSnapshotV2.get(owner.id);
    if (!snapshot) {
      snapshot = new TokenSnapshotV2(
        owner.id,
        owner.id,
        token.identifier,
        0,
        timestamp,
        tx.blockNumber,
        token.id
      );
    }

    snapshot.latestBlockTimestamp = timestamp;
    snapshot.latestBlockNumber = tx.blockNumber;
    snapshot.latestIdentifier = token.identifier;
    snapshot.latestTokenId = token.id;
    snapshot.tokensMinted += 1;

    toSave.push(snapshot);
  }

  if (contractForSnapshot.includes(contract.id)) {
    const snapshot = new TokenSnapshot(
      token.id,
      owner.id,
      tx.blockNumber,
      token.identifier,
      token.id,
      timestamp
    );

    toSave.push(snapshot);
  }

  return Promise.all(toSave.map((entity) => entity.save()));
}
