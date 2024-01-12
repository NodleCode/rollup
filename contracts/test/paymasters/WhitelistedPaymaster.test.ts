import { expect } from 'chai';
import { Contract, Provider, Wallet, utils } from "zksync-ethers";
import * as ethers from "ethers";
import { setupEnv } from './helpers';
import { deployContract } from '../../deploy/utils';

describe("WhitelistPaymaster", function () {
    let paymaster: Contract;
    let flag: Contract;
    let nodl: Contract;

    let adminWallet: Wallet;
    let withdrawerWallet: Wallet;
    let sponsorWallet: Wallet;
    let userWallet: Wallet;

    let provider: Provider;

    before(async function () {
        flag = await deployContract("MockFlag", [], { silent: true, skipChecks: true });

        const result = await setupEnv("WhitelistPaymaster", [[await flag.getAddress()]]);
        paymaster = result.paymaster;
        adminWallet = result.adminWallet;
        withdrawerWallet = result.withdrawerWallet;
        sponsorWallet = result.sponsorWallet;
        userWallet = result.userWallet;
        provider = result.provider;

        nodl = await deployContract("NODL", [adminWallet.address, adminWallet.address], { silent: true, skipChecks: true });

        // whitelist user
        const whitelistRole = await paymaster.WHITELISTED_USER_ROLE();
        const tx = await paymaster.connect(adminWallet).grantRole(whitelistRole, userWallet.address);
        await tx.wait();
    });

    it("only admin can update contract whitelist", async function () {
        const newFlag = await deployContract("MockFlag", [], { wallet: withdrawerWallet, silent: true, skipChecks: true });
        const newFlagAddress = await newFlag.getAddress();

        try {
            await paymaster.connect(userWallet).addWhitelistedContracts([newFlagAddress]);
        } catch (e) {
            expect(e.message).to.contain("Only admin can call this method");
        }

        try {
            await paymaster.connect(userWallet).removeWhitelistedContracts([newFlagAddress]);
        } catch (e) {
            expect(e.message).to.contain("Only admin can call this method");
        }

        const nonce = await adminWallet.getNonce();

        const tx1 = await paymaster.connect(adminWallet).addWhitelistedContracts([newFlagAddress], { nonce: nonce });
        await tx1.wait();
        expect(await paymaster.isWhitelistedContract(newFlagAddress)).to.be.true;
        expect(await paymaster.isWhitelistedContract(await flag.getAddress())).to.be.true;

        const tx2 = await paymaster.connect(adminWallet).removeWhitelistedContracts([newFlagAddress], { nonce: nonce + 1 });
        await tx2.wait();
        expect(await paymaster.isWhitelistedContract(newFlagAddress)).to.be.false;
        expect(await paymaster.isWhitelistedContract(await flag.getAddress())).to.be.true;
    });

    it("does not support approval based flow", async function () {
        const paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
            type: "ApprovalBased",
            token: await nodl.getAddress(),
            minimalAllowance: ethers.toBigInt(0),
            innerInput: new Uint8Array(),
        });

        try {
            await flag.connect(userWallet).setFlag("flag captured", {
                customData: {
                    gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
                    paymasterParams,
                },
            });
            expect(false).to.be.true; // Should not reach this line
        } catch (e) {
            expect(e.message).to.contain("execution reverted");
        }
    });

    it("supports calls to whitelisted contracts", async function () {
        const paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
            type: "General",
            innerInput: new Uint8Array(),
        });

        const tx = await flag.connect(userWallet).setFlag("flag captured", {
            customData: {
                gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
                paymasterParams,
            },
        });
        await tx.wait();

        expect(await flag.flag()).to.equal("flag captured");
    });

    it("does not support calls to non-whitelisted contracts", async function () {
        const newFlag = await deployContract("MockFlag", [], { silent: true, skipChecks: true });

        const paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
            type: "General",
            innerInput: new Uint8Array(),
        });

        try {
            await newFlag.connect(userWallet).setFlag("flag captured", {
                customData: {
                    gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
                    paymasterParams,
                },
            });
            expect(false).to.be.true; // Should not reach this line
        } catch (e) {
            expect(e.message).to.contain("execution reverted");
        }
    });

    it("does not support calls from non-whitelisted users", async function () {
        const paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
            type: "General",
            innerInput: new Uint8Array(),
        });

        try {
            await flag.connect(sponsorWallet).setFlag("flag captured", {
                customData: {
                    gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
                    paymasterParams,
                },
            });
            expect(false).to.be.true; // Should not reach this line
        } catch (e) {
            expect(e.message).to.contain("execution reverted");
        }
    });
});