import assert from "assert";
import { fetchContract, fetchToken } from "../utils/erc721";
import { fetchAccount, fetchMetadata, fetchTransaction } from "../utils/utils";
import { ApprovalLog, TransferLog } from "../types/abi-interfaces/MigrationNFTAbi";
import { ERC721Transfer } from "../types";
import { abi, callContract, nodleContracts } from "../utils/const";

export async function handleNFTTransfer(event: TransferLog): Promise<void> {
  assert(event.args, "No event.args");

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
          token.name = metadata.title || metadata.name || "";
          token.description = metadata.description || "";
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

export async function handleApproval(event: ApprovalLog): Promise<void> {
  assert(event.args, "No event.args");

  const contract = await fetchContract(event.address);
  if (contract) {
    const timestamp = event.block.timestamp * BigInt(1000);
    const to = await fetchAccount(event.args[1], timestamp);
    const from = await fetchAccount(event.args[0], timestamp);
    const tokenId = BigInt(event.args[2] as any);

    const token = await fetchToken(
      `${contract.id}/${tokenId}`,
      contract.id,
      tokenId,
      to.id,
      from.id
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
          token.name = metadata.title || metadata.name || "";
          token.description = metadata.description || "";
        }
      }
      token.uri = String(tokenUri);
    }

    token.ownerId = to.id;
    token.transactionHash = event.transaction.hash;
    token.timestamp = timestamp;

    return token.save();
  }
}
