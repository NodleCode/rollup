import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

dotenv.config();
const SHOULD_DEPLOY = false;
let CONTRACT_ADDRESS = "";

module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const rpcUrl = hre.network.config.url;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);
  const NAME = "NodleNameService";
  const SYMBOL = "NODLNS";

  console.log("Deploying NameService with name", NAME, "and symbol", SYMBOL);
  const constructorArgs = [
    process.env.GOV_ADDR!,
    process.env.REGISTRAR_ADDR!,
    NAME,
    SYMBOL,
  ];
  const artifact = await deployer.loadArtifact("NameService");

  if (SHOULD_DEPLOY) {
      const deploymentFee = await deployer.estimateDeployFee(
        artifact,
        constructorArgs
      );
      console.log(
        "NameService deployment fee (ETH): ",
        ethers.formatEther(deploymentFee)
      );
      const contract = await deployer.deploy(artifact, constructorArgs);
      await contract.waitForDeployment();
      CONTRACT_ADDRESS = await contract.getAddress();
      console.log("Deployed NameService at", CONTRACT_ADDRESS);

      // Verify contract
      console.log("Waiting for 5 confirmations...");
    await contract.deploymentTransaction()?.wait(5);
  }

  if (CONTRACT_ADDRESS) {
    console.log("Starting contract verification...");
    try {
      await hre.run("verify:verify", {
        address: CONTRACT_ADDRESS,
        contract: "src/nameservice/NameService.sol:NameService",
        constructorArguments: constructorArgs,
      });
      console.log("Contract verified successfully!");
    } catch (error: any) {
      if (error.message.includes("Contract source code already verified")) {
        console.log("Contract is already verified!");
      } else {
        console.error("Error verifying contract:", error);
        throw error;
      }
    }
  }
};
