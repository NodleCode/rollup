import { ERC20Contract } from "../types";
import { getContractDetails } from "./utils";

export const fetchContract = async (
  address: string
): Promise<ERC20Contract | null> => {
  // rewrite to lowercase
  const lowercaseAddress = address?.toLowerCase();

  const contract = await ERC20Contract.get(lowercaseAddress);

  if (!contract) {
    logger.info(`Contract not found for lowercaseAddress: ${lowercaseAddress}`);
    const newContract = new ERC20Contract(lowercaseAddress, lowercaseAddress);

    const { symbol, name, isErc20 } = await getContractDetails(
      lowercaseAddress
    );

    newContract.isValid = isErc20;

    newContract.symbol = symbol;
    newContract.name = name;
    await newContract.save();

    return newContract.isValid ? newContract : null;
  }

  return contract.isValid ? contract : null;
};
