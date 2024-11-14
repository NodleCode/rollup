import { ERC20Contract } from "../types";

export const fetchContract = async (
  address: string
): Promise<ERC20Contract> => {
  // rewrite to lowercase
  const lowercaseAddress = address?.toLowerCase();

  const contract = await ERC20Contract.get(lowercaseAddress);

  if (!contract) {
    logger.error(
      `Contract not found for lowercaseAddress: ${lowercaseAddress}`
    );
    const newContract = new ERC20Contract(lowercaseAddress, lowercaseAddress);
    newContract.save();

    return newContract;
  }

  return contract;
};
