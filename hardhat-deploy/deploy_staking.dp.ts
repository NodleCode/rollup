import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";

import { deployContract } from "./utils";

dotenv.config();

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const tokenAddress = requireEnv("STAKE_TOKEN");
  const adminAddress = requireEnv("GOV_ADDR");
  const minStakeAmount = requireEnv("MIN_STAKE");
  const stakingPeriod = requireEnv("DURATION");
  const rewardRate = requireEnv("REWARD_RATE");
  const maxTotalStake = requireEnv("MAX_TOTAL_STAKE");
  const requiredHoldingToken = requireEnv("REQUIRED_HOLDING_TOKEN");

  // REWARD_RATE is an integer percent and DURATION is an integer number of seconds
  if (!/^\d+$/.test(rewardRate)) {
    throw new Error(`REWARD_RATE must be a whole-number percent, got "${rewardRate}"`);
  }
  if (!/^\d+$/.test(stakingPeriod)) {
    throw new Error(`DURATION must be a whole number of seconds, got "${stakingPeriod}"`);
  }

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(requireEnv("DEPLOYER_PRIVATE_KEY"), provider);
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

  const staking = await deployContract(deployer, "Staking", constructorArgs);
  const contractAddress = await staking.getAddress();
  console.log(`Staking contract deployed at ${contractAddress}`);
  console.log(
    `!!! Do not forget to grant token approval to Staking contract at ${contractAddress} !!!`
  );

  console.log("Starting contract verification...");
  try {
    await hre.run("verify:verify", {
      address: contractAddress,
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
};
