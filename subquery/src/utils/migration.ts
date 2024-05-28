import { ERC20Contract, Proposal } from "../types";

export const fetchContract = async (
  address: string
): Promise<ERC20Contract> => {
  const contract = await ERC20Contract.get(address);

  if (!contract) {
    logger.error(`Contract not found for address: ${address}`);
    const newContract = new ERC20Contract(address, address);
    newContract.save();

    return newContract;
  }

  return contract;
};

export const fetchProposal = async (
  proposal: string
): Promise<Proposal> => {
  const contract = await Proposal.get(proposal);

  if (!contract) {
    logger.error(`Proposal not found for: ${proposal}`);
    const newContract = new Proposal(proposal);
    // newContract.save(); 

    return newContract;
  }

  return contract;
};
