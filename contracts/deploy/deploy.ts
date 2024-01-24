import { deployContract, getGovernance, getWhitelistAdmin } from "./utils";
import { execSync } from "child_process";

export default async function() {
    await deployContract("NODL", [getGovernance(), getGovernance()]);
    
    const nft = await deployContract("ContentSignNFT", ["Click", "CLK", getWhitelistAdmin()]);
    const nftAddress = await nft.getAddress();
    await deployContract("WhitelistPaymaster", [getGovernance(), getWhitelistAdmin(), [await nft.getAddress()]]);

    // used for docker compose setup so we can deploy a The Graph indexer on the NFT contract
    execSync(`echo "${nftAddress}" > .nft-contract-address`);
}