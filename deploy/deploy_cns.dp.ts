import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

dotenv.config();

module.exports = async function (hre: HardhatRuntimeEnvironment) {
    const rpcUrl = hre.network.config.url;
    const provider = new Provider(rpcUrl);
    const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
    const deployer = new Deployer(hre, wallet);

    console.log("Deploying ClickNameService...");
    const constructorArgs = [process.env.GOV_ADDR!, process.env.REGISTRAR_ADDR!];
    const artifact = await deployer.loadArtifact("ClickNameService");
    const deploymentFee = await deployer.estimateDeployFee(artifact, constructorArgs);
    console.log("ClickNameService deployment fee (ETH): ", ethers.formatEther(deploymentFee));
    const contract = await deployer.deploy(artifact, constructorArgs);
    await contract.waitForDeployment();
    const cnsAddress = await contract.getAddress();
    console.log("Deployed ClickNameService at", cnsAddress);
};
