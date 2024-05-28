import { ProposalContract } from "../types";

export const fetchContract = async (address: string): Promise<ProposalContract> => {
  const contract = await ProposalContract.get(address);

  if (!contract) {
    logger.error(`Contract not found for address: ${address}`);
    const newContract = new ProposalContract(address, address);
    newContract.save();

    return newContract;
  }

  return contract;
};
