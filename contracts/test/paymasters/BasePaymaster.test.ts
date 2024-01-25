import { expect } from 'chai';
import { Contract, Provider, Wallet, utils } from "zksync-ethers";
import * as ethers from "ethers";
import { setupEnv } from './helpers';
import { deployContract } from '../../deploy/utils';

describe("BasePaymaster", function () {
    let paymaster: Contract;
    let flag: Contract;
    let nodl: Contract;

    let adminWallet: Wallet;
    let withdrawerWallet: Wallet;
    let sponsorWallet: Wallet;
    let userWallet: Wallet;

    let provider: Provider;

    before(async function () {
        const result = await setupEnv("MockPaymaster");
        paymaster = result.paymaster;
        adminWallet = result.adminWallet;
        withdrawerWallet = result.withdrawerWallet;
        sponsorWallet = result.sponsorWallet;
        userWallet = result.userWallet;
        provider = result.provider;

        flag = await deployContract("MockFlag", [], { wallet: adminWallet, silent: true, skipChecks: true });
        nodl = await deployContract("NODL", [adminWallet.address, adminWallet.address], { wallet: adminWallet, silent: true, skipChecks: true });
    });

    async function executePaymasterTransaction(user: Wallet, type: "General" | "ApprovalBased", nonce: number, flagValue: string = "flag captured") {
        let paymasterParams;
        if (type === "General") {
            paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
                type: "General",
                innerInput: new Uint8Array(),
            });
        } else {
            paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
                type: "ApprovalBased",
                token: await nodl.getAddress(),
                minimalAllowance: ethers.toBigInt(0),
                innerInput: new Uint8Array(),
            });
        }

        await flag.connect(user).setFlag(flagValue, {
            nonce,
            customData: {
                gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
                paymasterParams,
            },
        });

        expect(await flag.flag()).to.equal(flagValue);
    }

    it("Can withdraw excess ETH", async () => {
        await expect(
            paymaster.connect(withdrawerWallet).withdraw(withdrawerWallet.address, ethers.parseEther("0.5"))
        ).to
            .changeEtherBalance(withdrawerWallet, ethers.parseEther("0.5"))
            .and.to.changeEtherBalance(await paymaster.getAddress(), ethers.parseEther("-0.5"));
    });

    it("Works as a paymaster", async () => {
        // no eth to pay for fees
        expect(await provider.getBalance(userWallet.address)).to.equal(ethers.toBigInt(0));

        // yet it works
        await executePaymasterTransaction(userWallet, "General", 0, "flag captured 1");
        await executePaymasterTransaction(userWallet, "ApprovalBased", 1, "flag captured 2");
    });

    it("Fails if not enough ETH", async () => {
        // withdraw all the ETH
        const toWithdraw = await provider.getBalance(paymaster.getAddress());
        await expect(
            paymaster.connect(withdrawerWallet).withdraw(withdrawerWallet.address, toWithdraw)
        ).to.changeEtherBalance(withdrawerWallet, toWithdraw);

        // paymaster cannot pay for txs anymore
        await expect(
            executePaymasterTransaction(userWallet, "General", 2)
        ).to.be.revertedWithoutReason();
    });

    it("Sets correct roles", async () => {
        const withdrawerRole = await paymaster.WITHDRAWER_ROLE();
        const adminRole = await paymaster.DEFAULT_ADMIN_ROLE();

        expect(await paymaster.hasRole(withdrawerRole, withdrawerWallet.address)).to.be.true;
        expect(await paymaster.hasRole(adminRole, adminWallet.address)).to.be.true;
    });
});