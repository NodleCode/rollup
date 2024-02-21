import { deployContract, getGovernance, getWhitelistAdmin } from "./utils";
import { execSync } from "child_process";

export default async function () {
  const nodl = await deployContract("NODL", [getGovernance(), getGovernance()]);
  const nodlAddress = await nodl.getAddress();

  const nft = await deployContract("ContentSignNFT", [
    "Click",
    "CLK",
    getWhitelistAdmin(),
  ]);
  const nftAddress = await nft.getAddress();
  await deployContract("WhitelistPaymaster", [
    getGovernance(),
    getGovernance(),
    getWhitelistAdmin(),
    [nftAddress],
  ]);

  const initialFeePrice = 1; // Means 1 nodl per 1 wei
  const priceOracle = getWhitelistAdmin(); // For now we assume that the whitelist admin is the same as the price oracle for NODL paymaster
  const paymasterContract = await deployContract("Erc20Paymaster", [
    getGovernance(),
    priceOracle,
    nodlAddress,
    initialFeePrice,
  ]);

  // used by some of microservices
  const multicallContract = await deployContract("MulticallBatcher");

  // create env var dump with all contract addresses
  const env = `\
NODL_ADDRESS=${nodlAddress}
NFT_ADDRESS=${nftAddress}
PAYMASTER_ADDRESS=${await paymasterContract.getAddress()}
MULTICALL_ADDRESS=${await multicallContract.getAddress()}`;
  execSync(`echo "${env}" > .contracts.env`);
}
