import { Wallet } from "zksync-ethers";
import * as ethers from "ethers";
import { LOCAL_RICH_WALLETS, deployContract, getProvider, getWallet } from "../../deploy/utils";

export const setupEnv = async (paymasterContract: string, additionalArgs: any[] = []) => {
    const provider = getProvider();

    const adminWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
    const withdrawerWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);
    const sponsorWallet = getWallet(LOCAL_RICH_WALLETS[2].privateKey);

    const paymaster = await deployContract(paymasterContract, [adminWallet.address, withdrawerWallet.address, ...additionalArgs], { wallet: adminWallet, silent: true, skipChecks: true });

    // send some ETH to it
    const tx = await sponsorWallet.sendTransaction({ to: await paymaster.getAddress(), value: ethers.parseEther("1") });
    await tx.wait();

    const emptyWallet = Wallet.createRandom();
    const userWallet = new Wallet(emptyWallet.privateKey, provider);

    return { paymaster, adminWallet, withdrawerWallet, sponsorWallet, userWallet, provider };
}