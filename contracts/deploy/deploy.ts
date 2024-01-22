import { deployContract, getGovernance, getWhitelistAdmin } from "./utils";

export default async function() {
    await deployContract("NODL", [getGovernance(), getGovernance()]);
    
    const factory = await deployContract("ContentSignNFT", ["Click", "CLK", getWhitelistAdmin()]);
    await deployContract("WhitelistPaymaster", [getWhitelistAdmin(), [await factory.getAddress()]]);
}