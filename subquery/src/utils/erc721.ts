import { EthereumLog, EthereumResult } from "@subql/types-ethereum";
import { Account, ERC721Contract, ERC721Operator, ERC721Token } from "../types";
import assert from "assert";
import { getContractDetails } from "./utils";

const knownAddresses = [
  "0x000000000000000000000000000000000000800a",
  "0x5a7d6b2f92c77fad6ccabd7ee0624e64907eaf3e",
];

export const fetchContract = async (
  address: string
): Promise<ERC721Contract | null> => {
  // rewrite to lowercase
  const lowercaseAddress = address?.toLowerCase();

  if (knownAddresses.includes(lowercaseAddress)) {
    return null;
  }

  const contract = await ERC721Contract.get(lowercaseAddress);

  if (!contract) {
    logger.info(`Contract not found for lowercaseAddress: ${lowercaseAddress}`);
    const newContract = new ERC721Contract(lowercaseAddress, lowercaseAddress);

    const { symbol, name, isErc721 } = await getContractDetails(
      lowercaseAddress
    );

    newContract.isValid = isErc721;

    newContract.symbol = symbol;
    newContract.name = name;
    await newContract.save();

    return newContract.isValid ? newContract : null;
  }

  return contract.isValid ? contract : null;
};

export const fetchToken = async (
  id: string,
  contractId: string,
  identifier: bigint,
  ownerId: string,
  approvalId: string,
  shouldLookup = true
): Promise<ERC721Token> => {
  const newToken = new ERC721Token(
    id,
    contractId,
    identifier,
    ownerId,
    approvalId
  );

  if (!shouldLookup) {
    logger.info(`Token id: ${id}`);
    return newToken;
  }
  
  const token = await ERC721Token.get(id);

  if (!token) {
    logger.info(`Token not found for id: ${id}`);

    // newToken.save();

    return newToken;
  }

  return token;
};

export const getApprovalLog = (
  logs: EthereumLog<EthereumResult>[],
  address: string
) => {
  const targetLog = logs.find((log) => log.args?.to === address);
  assert(targetLog, "No target log found");

  return targetLog.args;
};

export const fetchERC721Operator = async (
  contract: ERC721Contract,
  owner: Account,
  operator: Account
) => {
  const id = contract.id
    .concat("/")
    .concat(owner.id)
    .concat("/")
    .concat(operator.id);

  const op = await ERC721Operator.get(id);

  if (!op) {
    logger.info(`Operator not found for id: ${id}`);
    const newOp = new ERC721Operator(
      id,
      contract.id,
      owner.id,
      operator.id,
      false
    );
    newOp.save();

    return newOp;
  }

  return op;
};
