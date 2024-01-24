import { expect } from 'chai';
import { Contract, Provider, Wallet, utils } from "zksync-ethers";
import * as ethers from "ethers";
import { setupEnv } from './helpers';
import { LOCAL_RICH_WALLETS, deployContract, getWallet } from '../../deploy/utils';

describe("WhitelistPaymaster", function () {
    let paymaster: Contract;
    let flag: Contract;
    let nodl: Contract;

    let adminWallet: Wallet;
    let whitelistAdminWallet: Wallet;
    let withdrawerWallet: Wallet;
    let sponsorWallet: Wallet;
    let userWallet: Wallet;

    let provider: Provider;

    before(async function () {
        adminWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
        whitelistAdminWallet = getWallet(LOCAL_RICH_WALLETS[3].privateKey);
        flag = await deployContract("MockFlag", [], { wallet: adminWallet, silent: true, skipChecks: true });

        const result = await setupEnv("WhitelistPaymaster", [whitelistAdminWallet.address, [await flag.getAddress()]]);
        paymaster = result.paymaster;
        // adminWallet = result.adminWallet;
        withdrawerWallet = result.withdrawerWallet;
        sponsorWallet = result.sponsorWallet;
        userWallet = result.userWallet;
        provider = result.provider;

        nodl = await deployContract("NODL", [adminWallet.address, adminWallet.address], { wallet: adminWallet, silent: true, skipChecks: true });

        // whitelist user
        const whitelistedRole = await paymaster.WHITELISTED_USER_ROLE();
        const tx = await paymaster.connect(adminWallet).grantRole(whitelistedRole, userWallet.address, { nonce: await adminWallet.getNonce() });
        await tx.wait();
    });

    it("Sets correct roles", async () => {
        const adminRole = await paymaster.DEFAULT_ADMIN_ROLE();
        const withdrawerRole = await paymaster.WITHDRAWER_ROLE();
        const whitelistAdminRole = await paymaster.WHITELIST_ADMIN_ROLE();

        expect(await paymaster.hasRole(adminRole, adminWallet.address)).to.be.true;
        expect(await paymaster.hasRole(withdrawerRole, withdrawerWallet.address)).to.be.true;
        expect(await paymaster.hasRole(whitelistAdminRole, whitelistAdminWallet.address)).to.be.true;
    });

    it("Only whitelist admin can update contract whitelist", async function () {
        const newFlag = await deployContract("MockFlag", [], { wallet: withdrawerWallet, silent: true, skipChecks: true });
        const newFlagAddress = await newFlag.getAddress();

        try {
            await paymaster.connect(userWallet).addWhitelistedContracts([newFlagAddress]);
        } catch (e) {
            expect(e.message).to.contain("Only whitelist admin can call this method");
        }

        try {
            await paymaster.connect(userWallet).removeWhitelistedContracts([newFlagAddress]);
        } catch (e) {
            expect(e.message).to.contain("Only whitelist admin can call this method");
        }

        const nonce = await whitelistAdminWallet.getNonce();

        const tx1 = await paymaster.connect(whitelistAdminWallet).addWhitelistedContracts([newFlagAddress], { nonce: nonce });
        await tx1.wait();
        expect(await paymaster.isWhitelistedContract(newFlagAddress)).to.be.true;
        expect(await paymaster.isWhitelistedContract(await flag.getAddress())).to.be.true;

        const tx2 = await paymaster.connect(whitelistAdminWallet).removeWhitelistedContracts([newFlagAddress], { nonce: nonce + 1 });
        await tx2.wait();
        expect(await paymaster.isWhitelistedContract(newFlagAddress)).to.be.false;
        expect(await paymaster.isWhitelistedContract(await flag.getAddress())).to.be.true;
    });

    it("Does not support approval based flow", async function () {
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
            expect.fail("Should have reverted");
        } catch (e) {
            expect(e.message).to.contain("execution reverted");
        }
    });

    it("Supports calls to whitelisted contracts", async function () {
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

    it("Does not support calls to non-whitelisted contracts", async function () {
        const newFlag = await deployContract("MockFlag", [], { wallet: adminWallet, silent: true, skipChecks: true });

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
            expect.fail("Should have reverted");
        } catch (e) {
            expect(e.message).to.contain("execution reverted");
        }
    });

    it("Does not support calls from non-whitelisted users", async function () {
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
            expect.fail("Should have reverted");
        } catch (e) {
            expect(e.message).to.contain("execution reverted");
        }
    });
});