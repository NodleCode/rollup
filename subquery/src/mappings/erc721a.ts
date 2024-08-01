import assert from "assert";
import { fetchContract, fetchToken } from "../utils/erc721";
import { fetchAccount, fetchMetadata, fetchTransaction } from "../utils/utils";
import { ApprovalLog, TransferLog } from "../types/abi-interfaces/Erc721Abi";
import { ERC721Transfer } from "../types";
import { abi, callContract, nodleContracts } from "../utils/const";

export async function handleNFTTransfer(event: TransferLog): Promise<void> {
  assert(event.args, "No event.args");

  const contract = await fetchContract(event.address);
  if (contract) {
    // logger.info("handleNFTTransfer");
    // logger.info(JSON.stringify(event.args));
    const from = await fetchAccount(event.args[0]);
    const to = await fetchAccount(event.args[1]);
    const tokenId = event.args[2];

    const transferTx = await fetchTransaction(
      event.transaction.hash,
      event.block.timestamp * BigInt(1000),
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
      logger.info("Token URI: " + tokenUri);
      if (tokenUri && nodleContracts.includes(contract.id)) {
        const metadata = await fetchMetadata(tokenUri, [
          "nodle-community-nfts.myfilebase.com",
          "pinning.infura-ipfs.io",
          "nodle-web-wallet.infura-ipfs.io",
          "cloudflare-ipfs.com",
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
    const to = await fetchAccount(event.args[1]);
    const from = await fetchAccount(event.args[0]);
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
      logger.info("Token URI: " + tokenUri);
      if (tokenUri && nodleContracts.includes(contract.id)) {
        const metadata = await fetchMetadata(tokenUri, [
          "nodle-community-nfts.myfilebase.com",
          "pinning.infura-ipfs.io",
          "nodle-web-wallet.infura-ipfs.io",
          "cloudflare-ipfs.com",
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
    token.timestamp = event.block.timestamp * BigInt(1000);

    return token.save();
  }
}
