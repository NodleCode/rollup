import { deployContract, getGovernance, getWhitelistAdmin } from "./utils";
import { execSync } from "child_process";

export default async function() {
    await deployContract("NODL", [getGovernance(), getGovernance()]);
    
    const nft = await deployContract("ContentSignNFT", ["Click", "CLK", getWhitelistAdmin()]);
    const nftAddress = await nft.getAddress();
    await deployContract("WhitelistPaymaster", [getWhitelistAdmin(), [nftAddress]]);

    // run commands with new address, create a file with the address
    execSync(`echo "${nftAddress}" > .nft-contract-address`);
}