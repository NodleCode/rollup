import { deployContract, getGovernance } from "./utils";

export default async function() {
    await deployContract("NODL", [getGovernance()]);
}