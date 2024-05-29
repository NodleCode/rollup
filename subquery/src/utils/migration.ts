import { Proposal, ProposalContract } from "../types";

export const fetchContract = async (
  address: string
): Promise<ProposalContract> => {
  // rewrite to lowercase
  const lowercaseAddress = address?.toLowerCase();

  const contract = await ProposalContract.get(lowercaseAddress);

  if (!contract) {
    logger.error(
      `Contract not found for lowercaseAddress: ${lowercaseAddress}`
    );
    const newContract = new ProposalContract(
      lowercaseAddress,
      lowercaseAddress
    );
    newContract.save();

    return newContract;
  }

  return contract;
};


export const fetchProposal = async (
  proposal: string
): Promise<Proposal> => {
  const prop = await Proposal.get(proposal);

  if (!prop) {
    logger.error(`Proposal not found for: ${proposal}`);
    const newProp = new Proposal(proposal);
    newProp.save(); 

    return newProp;
  }

  return prop;
};
