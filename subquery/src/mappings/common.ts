import {
  ERC20Approval,
  ERC20Contract,
  ERC20Transfer,
  ERC721Contract,
  ERC721Token,
  ERC721Transfer,
} from "../types";
import { ApprovalLog, TransferLog } from "../types/abi-interfaces/Erc721Abi";
import { TransferLog as TransferLogERC20 } from "../types/abi-interfaces/Erc20Abi";
import {
  fetchAccount,
  fetchMetadata,
  fetchTransaction,
  getContractDetails,
} from "../utils/utils";
import { abi, callContract, nodleContracts } from "../utils/const";
import { fetchToken } from "../utils/erc721";

const knownAddresses = [
  "0x000000000000000000000000000000000000800a",
  "0x5a7d6b2f92c77fad6ccabd7ee0624e64907eaf3e",
];

export async function handleTransfer(event: TransferLog) {
  try {
    const lowercaseAddress = event?.address?.toLowerCase();

    if (knownAddresses.includes(lowercaseAddress)) {
      return;
    }

    let contract: ERC20Contract | ERC721Contract | undefined =
      (await ERC20Contract.get(lowercaseAddress)) ||
      (await ERC721Contract.get(lowercaseAddress));

    if (!contract) {
      const { symbol, name, isErc20, isErc721 } = await getContractDetails(
        lowercaseAddress
      );
      logger.info(
        `Contract details in handleTransfer: ${symbol}, ${name}, ${isErc721}, ${isErc20}`
      );
      let newContract = isErc721
        ? new ERC721Contract(lowercaseAddress, lowercaseAddress)
        : new ERC20Contract(lowercaseAddress, lowercaseAddress);

      newContract.isValid = isErc20 || isErc721 ? true : false;

      newContract.symbol = symbol;
      newContract.name = name;

      await newContract.save();
      contract = newContract.isValid ? newContract : undefined;
    }

    if (contract?.isValid) {
      if (contract._name === "ERC721Contract") {
        return handleNFTTransfer(event, contract);
      } else if (contract._name === "ERC20Contract") {
        return handleERC20Transfer(event as TransferLogERC20, contract);
      }
    }
  } catch (error) {
    logger.error(JSON.stringify(error));
  }
}

export async function handleERC20Transfer(
  event: TransferLogERC20,
  contract: ERC20Contract
) {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  if (contract?.isValid) {
    const from = await fetchAccount(event.args[0]);
    const to = await fetchAccount(event.args[1]);
    const emmiter = await fetchAccount(event.transaction.from);
    const value = event.args[2].toBigInt();
    const timestamp = event.block.timestamp * BigInt(1000);
    const hash = event.transaction.hash;

    const transaction = await fetchTransaction(
      hash,
      timestamp,
      BigInt(event.blockNumber)
    );

    const transferEvent = new ERC20Transfer(
      contract.id
        .concat("/")
        .concat(hash)
        .concat("/")
        .concat(`${event.logIndex}`),
      emmiter.id,
      transaction.id,
      timestamp,
      from.id,
      to.id,
      value
    );

    transferEvent.hash = hash;
    transferEvent.contractId = contract.id;
    transferEvent.emitterId = emmiter.id;
    return [transferEvent, transaction];
  }
}

export async function handleNFTTransfer(
  event: TransferLog,
  contract: ERC721Contract
) {
  if (!event.args) {
    logger.error("No event.args: " + JSON.stringify(event));
    return;
  }

  if (contract?.isValid) {
    const from = await fetchAccount(event.args[0]);
    const to = await fetchAccount(event.args[1]);
    const tokenId = event.args[2];

    const transaction = await fetchTransaction(
      event.transaction.hash,
      event.block.timestamp * BigInt(1000),
      BigInt(event.block.number)
    );

    const token = await fetchToken(
      `${contract.id}/${tokenId}`,
      contract.id,
      BigInt(tokenId as any),
      to.id,
      "",
      from.id !== "0x0000000000000000000000000000000000000000"
    );

    const transfer = new ERC721Transfer(
      `${contract.id}/${token.id}`,
      from.id,
      transaction.id,
      event.block.timestamp * BigInt(1000),
      contract.id,
      token.id,
      from.id,
      to.id
    );

    token.ownerId = to.id;
    token.transactionHash = event.transaction.hash;
    token.timestamp = event.block.timestamp * BigInt(1000);

    const tokenToSave = await getTokenWithUri(
      contract.id,
      tokenId.toBigInt(),
      token
    );

    return [transfer, transaction, tokenToSave];
  }
}

export async function handleApproval(event: ApprovalLog) {
  try {
    const lowercaseAddress = event?.address?.toLowerCase();

    if (knownAddresses.includes(lowercaseAddress)) {
      return;
    }

    let contract: ERC20Contract | ERC721Contract | undefined =
      (await ERC20Contract.get(lowercaseAddress)) ||
      (await ERC721Contract.get(lowercaseAddress));

    if (!contract) {
      logger.info(
        `Contract not found for lowercaseAddress in handleApproval: ${lowercaseAddress}`
      );

      const { symbol, name, isErc20, isErc721 } = await getContractDetails(
        lowercaseAddress
      );

      let newContract = isErc721
        ? new ERC721Contract(lowercaseAddress, lowercaseAddress)
        : new ERC20Contract(lowercaseAddress, lowercaseAddress);

      newContract.isValid = isErc20 || isErc721 ? true : false;

      newContract.symbol = symbol;
      newContract.name = name;

      await newContract.save();
      contract = newContract.isValid ? newContract : undefined;
    }

    if (contract?.isValid) {
      if (contract._name === "ERC20Contract") {
        return handleERC20Approval(event, contract);
      } else if (contract._name === "ERC721Contract") {
        return handleERC721Approval(event, contract);
      }
    }
  } catch (error) {
    logger.error(JSON.stringify(error));
  }
}

export async function handleERC20Approval(
  event: ApprovalLog,
  contract: ERC20Contract
) {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }

  if (contract?.isValid) {
    const owner = await fetchAccount(event.args[0]);
    const spender = await fetchAccount(event.args[1]);
    const value = event.args[2].toBigInt();
    const timestamp = event.block.timestamp * BigInt(1000);
    const hash = event.transaction.hash;
    const emmiter = await fetchAccount(event.transaction.from);

    const transaction = await fetchTransaction(
      hash,
      timestamp,
      BigInt(event.blockNumber)
    );

    const approval = new ERC20Approval(
      contract.id.concat("/").concat(hash),
      emmiter.id,
      transaction.id,
      timestamp,
      owner.id,
      spender.id,
      value
    );

    approval.contractId = contract.id;
    approval.hash = hash;

    return [approval, transaction];
  }
}

export async function handleERC721Approval(
  event: ApprovalLog,
  contract: ERC721Contract
) {
  if (!event.args) {
    logger.error("No event.args: " + JSON.stringify(event));
    return;
  }

  if (contract?.isValid) {
    const to = await fetchAccount(event.args[1]);
    const from = await fetchAccount(event.args[0]);
    const tokenId = BigInt(event.args[2] as any);

    const token = await fetchToken(
      `${contract.id}/${tokenId}`,
      contract.id,
      tokenId,
      to.id,
      "",
      from.id !== "0x0000000000000000000000000000000000000000"
    );

    token.ownerId = to.id;
    token.transactionHash = event.transaction.hash;
    token.timestamp = event.block.timestamp * BigInt(1000);

    const toSave = await getTokenWithUri(contract.id, tokenId, token);

    return [toSave];
  }
}

const getTokenWithUri = async (
  contractId: string,
  tokenId: bigint,
  token: ERC721Token
): Promise<ERC721Token> => {
  if (
    !token.uri &&
    nodleContracts.includes(String(contractId).toLocaleLowerCase())
  ) {
    const tokenUri = await callContract(contractId, abi, "tokenURI", [
      tokenId,
    ]).catch((error) => {
      return null;
    });
    // logger.info("Token URI: " + tokenUri);
    if (tokenUri) {
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

  return token;
};
