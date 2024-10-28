import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

dotenv.config();

module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const oracleAddress = process.env.N_ORACLE_ADDR!;
  const adminAddress = process.env.N_ADMIN_ADDR!;
  const tokenAddress = process.env.N_TOKEN_ADDR;
  const initialQuota = BigInt(process.env.N_INITIAL_QUOTA!);
  const initialPeriod = BigInt(process.env.N_INITIAL_PERIOD!);

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const constructorArgs = [
    oracleAddress,
    tokenAddress,
    initialQuota.toString(),
    initialPeriod.toString(),
    adminAddress,
  ];

  console.log(
    "Deploying Payment contract with constructor args: ",
    constructorArgs
  );

  const artifact = await deployer.loadArtifact("Payment");
  const fee = await deployer.estimateDeployFee(
    artifact,
    constructorArgs
  );
  console.log(
    "Rewards deployment fee (ETH): ",
    ethers.formatEther(fee)
  );

  const contract = await deployer.deploy(
    artifact,
    constructorArgs
  );
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log("Deployed Payment contract at", address);

  console.log(`!!! Do not forget to fund budget to Payment contract at ${address}`);
};
