import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

import { deployContract } from "./utils";

dotenv.config();
let CONTRACT_ADDRESS = "";
let SHOULD_DEPLOY = !CONTRACT_ADDRESS;

module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const tokenAddress = process.env.STAKE_TOKEN!;
  const adminAddress = process.env.GOV_ADDR!;
  const minStakeAmount = process.env.MIN_STAKE!;
  const stakingPeriod = process.env.DURATION!;
  const rewardRate = process.env.REWARD_RATE!;
  const maxTotalStake = process.env.MAX_TOTAL_STAKE!;
  const requiredHoldingToken = process.env.REQUIRED_HOLDING_TOKEN!;

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const constructorArgs = [
    tokenAddress,
    (BigInt(requiredHoldingToken) * BigInt(1e18)).toString(),
    Number(rewardRate),
    (BigInt(minStakeAmount) * BigInt(1e18)).toString(),
    (BigInt(maxTotalStake) * BigInt(1e18)).toString(),
    Number(stakingPeriod),
    adminAddress,
  ];

  if (SHOULD_DEPLOY) {
    const staking = await deployContract(deployer, "Staking", constructorArgs);
    CONTRACT_ADDRESS = await staking.getAddress();
    console.log(`Staking contract deployed at ${await staking.getAddress()}`);
    console.log(
      `!!! Do not forget to grant token approval to Staking contract at ${await staking.getAddress()} !!!`
    );
  }

  if (CONTRACT_ADDRESS) {
    console.log("Starting contract verification...");
    try {
      await hre.run("verify:verify", {
        address: CONTRACT_ADDRESS,
        contract: "src/Staking.sol:Staking",
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
