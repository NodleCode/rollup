import { deployContract, getGovernance, getWhitelistAdmin } from "./utils";
import { execSync } from "child_process";

export default async function() {
    await deployContract("NODL", [getGovernance(), getGovernance()]);
    
    const factory = await deployContract("ContentSignNFT", ["Click", "CLK", getWhitelistAdmin()]);
    const factoryAddress = await factory.getAddress();
    await deployContract("WhitelistPaymaster", [getWhitelistAdmin(), [factoryAddress]]);

    // run commands with new address, create a file with the address
    execSync(`echo "${factoryAddress}" > .factory-address`);
}