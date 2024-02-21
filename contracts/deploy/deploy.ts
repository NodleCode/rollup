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

  // used for docker compose setup so we can deploy a The Graph indexer on the NFT contract
  execSync(`echo "${nftAddress}" > .nft-contract-address`);
}
