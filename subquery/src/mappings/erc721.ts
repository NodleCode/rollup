import assert from "assert";
import {
  fetchContract,
  fetchERC721Operator,
  fetchToken,
  getApprovalLog,
} from "../utils/erc721";
import {
  TransferLog,
  ApprovalForAllLog,
  SafeMintTransaction,
} from "../types/abi-interfaces/Erc721Abi";
import { fetchAccount, fetchMetadata, fetchTransaction } from "../utils/utils";

const keysMapping = {
  application: "Application",
  channel: "Channel",
  contentType: "Content Type",
  duration: "Duration (sec)",
  captureDate: "Capture date",
  longitude: "Longtitude",
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
  assert(event.args, "No event.args");

  const contract = await fetchContract(event.address);
  /* if (contract) {
    const from = await fetchAccount(event.args.from);
    const to = await fetchAccount(event.args.to);

    const tokenId = event.args.tokenId;

    const token = await fetchToken(
      `${contract.id}/${tokenId}`,
      contract.id,
      tokenId.toBigInt(),
      from.id,
      from.id
    );

    token.ownerId = to.id;

    return token.save();
  } */
}

// This event is not being emitted by the contract, it is an issue?
/* export function handleApproval(event: ApprovalLog): Promise<void> {
  logger.info("handleApproval: " + JSON.stringify(event));
  // const account = await fetchAccount();

  return Promise.resolve();
} */

export async function handleApprovalForAll(event: ApprovalForAllLog) {
  assert(event.args, "No event.args");

  const contract = await fetchContract(event.address);
  if (contract != null) {
    const timestamp = event.block.timestamp * BigInt(1000);
    const owner = await fetchAccount(event.args.owner, timestamp);
    const operator = await fetchAccount(event.args.operator, timestamp);

    const delegation = await fetchERC721Operator(contract, owner, operator);

    delegation.approved = event.args.approved;

    return delegation.save();
  }
}

export async function handleSafeMint(tx: SafeMintTransaction) {
  assert(tx.args, "No tx.args");
  assert(tx.logs, "No tx.logs");

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

  if (uri) {
    const metadata = await fetchMetadata(uri, [
      "nodle-community-nfts.myfilebase.com",
      "pinning.infura-ipfs.io",
      "nodle-web-wallet.infura-ipfs.io",
      "cloudflare-ipfs.com",
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
          token.captureDate = objectAttributes[keysMapping.captureDate] ? BigInt(objectAttributes[keysMapping.captureDate]) : BigInt(0);
          token.longitude = objectAttributes[keysMapping.longitude] ? parseFloat(objectAttributes[keysMapping.longitude]) : 0;
          token.latitude = objectAttributes[keysMapping.latitude] ? parseFloat(objectAttributes[keysMapping.latitude]) : 0;
          token.locationPrecision =
            objectAttributes[keysMapping.locationPrecision];
        }
      }
    }
  }

  return Promise.all([
    contract.save(),
    safeMintTx.save(),
    caller.save(),
    owner.save(),
    token.save(),
  ]);
}
