import assert from "assert";
import { fetchContract, fetchERC721Operator, fetchToken, getApprovalLog } from "../utils/erc721";
import { TransferLog, ApprovalForAllLog, SafeMintTransaction, ApprovalLog } from "../types/abi-interfaces/Erc721Abi";
import { fetchAccount, fetchMetadata, fetchTransaction } from "../utils/utils";

export async function handleTransfer(event: TransferLog): Promise<void>  {
  assert(event.args, "No event.args");

  console.log("handleTransfer: " + JSON.stringify(event.args));

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
export function handleApproval(event: ApprovalLog): Promise<void> {
  logger.info("handleApproval: " + JSON.stringify(event.args));
  // const account = await fetchAccount();

  return Promise.resolve();
}

export async function handleApprovalForAll(event: ApprovalForAllLog) {
  assert(event.args, "No event.args");

  const contract = await fetchContract(event.address);
  if (contract != null) {
    const owner = await fetchAccount(event.args.owner);
    const operator = await fetchAccount(event.args.operator);

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
  const caller = await fetchAccount(String(tx.from).toLowerCase());

  const owner = await fetchAccount(String(await tx.args[0]).toLowerCase());
  const uri = await tx.args[1];

  const tokenId = getApprovalLog(tx.logs, await tx.args[0])![2].toBigInt();

  const token = await fetchToken(
    `${contract.id}/${tokenId}`,
    contract.id,
    tokenId,
    owner.id,
    caller.id
  );

  token.timestamp = BigInt(tx.blockTimestamp) * BigInt(1000);

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
