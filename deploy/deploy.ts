import { deployContract } from "./utils";

export default async function () {
    const nodle = await deployContract("EnterpriseContentSign", ["Nodle via ContentSign", "NSIGN"]);
    const vivendi = await deployContract("EnterpriseContentSign", ["Vivendi via ContentSign", "VSIGN"]);

    console.log("EnterpriseContentSign deployed to:", await nodle.getAddress());
    console.log("EnterpriseContentSign deployed to:", await vivendi.getAddress());

    console.log("Don't forget to add addresses to whitelist on mainnet");
}