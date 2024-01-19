import { deployContract, getGovernance } from "./utils";

export default async function() {
    await deployContract("NODL", [getGovernance(), getGovernance()]);
    await deployContract("ContentSignNFT", [getGovernance(), getGovernance()]);
    await deployContract("WhitelistPaymaster", [getGovernance(), getGovernance(), []]);
}