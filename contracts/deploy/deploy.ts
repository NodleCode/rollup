import { deployContract, getGovernance, getWallet } from "./utils";
import { execSync } from "child_process";

export default async function () {
  const nodl = await deployContract("NODL", [getGovernance(), getGovernance()]);
  const paymaster = await deployContract("WhitelistPaymaster", [
    getGovernance(),
    getGovernance(),
    getWallet().address,
    [],
  ]);
  const nft = await deployContract("ContentSignNFT", [
    "Click",
    "CLK",
    await paymaster.getAddress(),
  ]);

  console.log("Configuring whitelist...");

  const contractTx = await paymaster
    .connect(getWallet())
    .addWhitelistedContracts([await nft.getAddress()]);
  const contractHash = await contractTx.wait().then((tx) => tx.transactionHash);

  console.log(`Whitelist configured at ${await contractHash}`);

  // unused for now
  // const initialFeePrice = 1; // Means 1 nodl per 1 wei
  // const priceOracle = getWallet(); // For now we assume that the whitelist admin is the same as the price oracle for NODL paymaster
  // const paymasterContract = await deployContract("Erc20Paymaster", [
  //   getGovernance(),
  //   priceOracle,
  //   nodlAddress,
  //   initialFeePrice,
  // ]);

  // create env var dump with all contract addresses
  const env = `\
NODL_ADDRESS=${await nodl.getAddress()}
NFT_ADDRESS=${await nft.getAddress()}
WHITELIST_PAYMASTER_ADDRESS=${await paymaster.getAddress()}`;

  execSync(`echo "${env}" > .contracts.env`);
}
