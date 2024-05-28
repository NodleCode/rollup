import { EthereumLog, EthereumResult } from "@subql/types-ethereum";
import { Account, ERC721Contract, ERC721Operator, ERC721Token } from "../types";
import assert from "assert";

export const fetchContract = async (address: string): Promise<ERC721Contract> => {
  // rewrite to lowercase
  const lowercaseAddress = address?.toLowerCase();


  const contract = await ERC721Contract.get(lowercaseAddress);

  if (!contract) {
    logger.error(`Contract not found for lowercaseAddress: ${lowercaseAddress}`);
    const newContract = new ERC721Contract(lowercaseAddress, lowercaseAddress);
    newContract.save();

    return newContract;
  }

  return contract;
};

export const fetchToken = async (
  id: string,
  contractId: string,
  identifier: bigint,
  ownerId: string,
  approvalId: string
): Promise<ERC721Token> => {
  const token = await ERC721Token.get(id);

  if (!token) {
    logger.error(`Token not found for id: ${id}`);
    const newToken = new ERC721Token(
      id,
      contractId,
      identifier,
      ownerId,
      approvalId
    );
    newToken.save();

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
    logger.error(`Operator not found for id: ${id}`);
    const newOp = new ERC721Operator(id, contract.id, owner.id, operator.id, false);
    newOp.save();

    return newOp;
  }

  return op;
};