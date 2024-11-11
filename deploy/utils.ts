import { ethers } from "ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";

export async function deployContract(deployer: Deployer, artifactName: string, constructorArgs: any) {
    console.log(
        `Deploying ${artifactName} contract with constructor args: `,
        constructorArgs
    );

    const artifact = await deployer.loadArtifact(artifactName);
    const fee = await deployer.estimateDeployFee(
        artifact,
        constructorArgs
    );
    console.log(
        `${artifactName} deployment fee (ETH): `,
        ethers.formatEther(fee)
    );

    const contract = await deployer.deploy(
        artifact,
        constructorArgs
    );
    await contract.waitForDeployment();

    console.log(`${artifactName} deployed at ${await contract.getAddress()}`);

    return contract;
}
