import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

import { deployContract } from "./utils";

dotenv.config();

module.exports = async function (hre: HardhatRuntimeEnvironment) {
    const nodlAddress = process.env.N_TOKEN_ADDR!;
    const minVotes = 3;
    const minDelay = 86400;
    const oracles = process.env.N_RELAYERS!.split(",");

    const rpcUrl = hre.network.config.url!;
    const provider = new Provider(rpcUrl);
    const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
    const deployer = new Deployer(hre, wallet);

    const grants = await deployContract(deployer, "Grants", [
        nodlAddress,
        "1000000000000000000000",
        100,
    ]);
    const grantsMigration = await deployContract(deployer, "GrantsMigration", [
        oracles,
        nodlAddress,
        await grants.getAddress(),
        minVotes,
        minDelay,
    ]);

    console.log(
        `!!! Do not forget to grant minting role for GrantsMigration at ${await grantsMigration.getAddress()} !!!`
    );
};
