import { Proposal, ProposalContract, ProposalGrant } from "../types";

export const fetchContract = async (
  address: string
): Promise<ProposalContract> => {
  // rewrite to lowercase
  const lowercaseAddress = address?.toLowerCase();

  const contract = await ProposalContract.get(lowercaseAddress);

  if (!contract) {
    const newContract = new ProposalContract(
      lowercaseAddress,
      lowercaseAddress
    );
    newContract.save();

    return newContract;
  }

  return contract;
};

export const fetchProposal = async (proposal: string): Promise<Proposal> => {
  const contract = await Proposal.get(proposal);

  if (!contract) {
    logger.error(`Proposal not found for: ${proposal}`);
    const newContract = new Proposal(proposal);
    newContract.save();

    return newContract;
  }

  return contract;
};

export const fetchGrantProposal = async (proposal: string): Promise<ProposalGrant> => {
  const contract = await ProposalGrant.get(proposal);

  if (!contract) {
    logger.error(`Proposal not found for: ${proposal}`);
    const newContract = new ProposalGrant(proposal);
    newContract.save();

    return newContract;
  }

  return contract;
};
