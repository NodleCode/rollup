import { Wallet } from "zksync-ethers";
import * as ethers from "ethers";
import {
  LOCAL_RICH_WALLETS,
  deployContract,
  getWallet,
} from "../../deploy/utils";

export const setupEnv = async (
  paymasterContract: string,
  additionalArgs: any[] = [],
) => {
  const adminWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
  const withdrawerWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);
  const sponsorWallet = getWallet(LOCAL_RICH_WALLETS[2].privateKey);

  const paymaster = await deployContract(
    paymasterContract,
    [adminWallet.address, ...additionalArgs],
    { wallet: adminWallet, silent: true, skipChecks: true },
  );
  await paymaster.waitForDeployment();

  await paymaster
    .connect(adminWallet)
    .grantRole(await paymaster.WITHDRAWER_ROLE(), withdrawerWallet.address);
  await sponsorWallet.sendTransaction({
    to: await paymaster.getAddress(),
    value: ethers.parseEther("1"),
  });

  return {
    paymaster,
    adminWallet,
    withdrawerWallet,
    sponsorWallet,
  };
};
