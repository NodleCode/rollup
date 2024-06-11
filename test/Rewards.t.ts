import { expect } from "chai";
import { Contract, Wallet } from "zksync-ethers";
import { getWallet, deployContract, LOCAL_RICH_WALLETS, getRandomWallet } from "../script/utils";
import * as ethers from "ethers";

describe("Rewards", function () {
    let tokenContract: Contract;
    let rewardsContract: Contract;
    let ownerWallet: Wallet;
    let userWallet: Wallet;

    const mintAmount = 1000n;

    before(async function () {
        ownerWallet = getWallet();
        userWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);

        tokenContract = await deployContract(
            "NODL",
            [],
            { wallet: ownerWallet, silent: false, skipChecks: false },
        );
        await tokenContract.waitForDeployment();
        const tokenAddress = await tokenContract.getAddress();

        rewardsContract = await deployContract(
            "Rewards",
            [tokenAddress],
            { wallet: ownerWallet, silent: false, skipChecks: false },
        );
        await rewardsContract.waitForDeployment();
        const rewardsAddress = await rewardsContract.getAddress();

        const minterRole = await tokenContract.MINTER_ROLE();
        const grantRoleTx = await tokenContract
            .connect(ownerWallet)
            .grantRole(minterRole, rewardsAddress);
        grantRoleTx.wait();

    });

    it("batch rewards to a number of random users should work", async () => {
        const balanceBefore = await tokenContract.balanceOf(userWallet.address);

        const minTx = await tokenContract
            .connect(ownerWallet)
            .mint(userWallet.address, mintAmount);
        const mintReceipt = await minTx.wait();

        const balanceAfterMint = await tokenContract.balanceOf(userWallet.address);
        expect(balanceAfterMint).to.equal(balanceBefore + mintAmount);

        const rewardBatchSize = 500;
        const addresses: string[] = [];
        for (let i = 0; i < rewardBatchSize; i++) {
            const wallet = getRandomWallet();
            addresses.push(wallet.address);
        }
        const amounts = Array(rewardBatchSize).fill(mintAmount);

        const mintRewardTx = await rewardsContract.connect(ownerWallet).batchMint(addresses, amounts);
        const rewardReceipt = await mintRewardTx.wait();

        const totalSupply = await tokenContract.totalSupply();
        expect(totalSupply).to.equal(mintAmount * BigInt(rewardBatchSize + 1));

        console.log(`Gas used for minting: ${mintReceipt.gasUsed.toString()} vs ${rewardReceipt.gasUsed.toString()} for minting with rewards`);
    });
});