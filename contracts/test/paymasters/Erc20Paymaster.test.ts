import { expect } from 'chai';
import { Contract, Wallet, utils } from "zksync-ethers";
import * as ethers from "ethers";
import { LOCAL_RICH_WALLETS, deployContract, getProvider, getWallet } from '../../deploy/utils';

describe("Erc20Paymaster", function () {
    let paymaster: Contract;
    let nodl: Contract;
    let adminWallet: Wallet;
    let oracleWallet: Wallet;
    let oracleRole: string;
    let adminRole: string;
    let adminNonce: number;

    const initialFeePrice = 1; // Means 1 nodle per 1 wei

    before(async function () {
        const emptyWallet = Wallet.createRandom();

        adminWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
        oracleWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);

        
        adminNonce = await adminWallet.getNonce(); 

        nodl = await deployContract("NODL", [adminWallet.address, adminWallet.address], { wallet: adminWallet, silent: true, skipChecks: true }, adminNonce++);
        const nodlAddress = await nodl.getAddress();

        paymaster = await deployContract("Erc20Paymaster", [adminWallet.address, oracleWallet.address, nodlAddress, initialFeePrice], { wallet: adminWallet, silent: true, skipChecks: true }, adminNonce++);
        const paymasterAddress = await paymaster.getAddress();
        oracleRole = await paymaster.PRICE_ORACLE_ROLE();
        adminRole = await paymaster.DEFAULT_ADMIN_ROLE();
        
        const transactionResponse = await adminWallet.sendTransaction({ to: paymasterAddress, value: ethers.parseEther("1"), nonce: adminNonce++ });
        await transactionResponse.wait();    
    });

    it("Roles are set correctly", async () => {
        expect(await paymaster.hasRole(adminRole, adminWallet.address)).to.be.true;
        expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be.true;
    });

    it("Oracle can update fee price", async () => {
        expect(await paymaster.feePrice()).to.be.equal(initialFeePrice);
        const newFeePrice = 2;
        await paymaster.connect(oracleWallet).updateFeePrice(newFeePrice);
        expect(await paymaster.feePrice()).to.be.equal(newFeePrice);
    });

    it("None oracle can't update fee price", async () => {
        const newFeePrice = 3;
        await expect(paymaster.connect(adminWallet).updateFeePrice(newFeePrice, { nonce: adminNonce })).to.be.revertedWithCustomError(paymaster, "AccessControlUnauthorizedAccount").withArgs(adminWallet.address, oracleRole);
    });

    it("Admin can grant oracle role", async () => {       
        const newOracleWallet = Wallet.createRandom();
        await paymaster.connect(adminWallet).grantPriceOracleRole(newOracleWallet.address, { nonce: adminNonce++ });
        expect(await paymaster.hasRole(oracleRole, newOracleWallet.address)).to.be.true;
        expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be.true;
    });

    it("Admin can revoke oracle role", async () => {
        await paymaster.connect(adminWallet).revokePriceOracleRole(oracleWallet.address, { nonce: adminNonce++ });
        expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be.false;
    });

    it("Non Admin cannot grant or revoke roles", async () => {  
        const newOracleWallet = Wallet.createRandom(getProvider());
        await expect(paymaster.connect(oracleWallet).grantPriceOracleRole(newOracleWallet.address)).to.be.revertedWithCustomError(paymaster, "AccessControlUnauthorizedAccount").withArgs(oracleWallet.address, adminRole);
        await expect(paymaster.connect(newOracleWallet).revokePriceOracleRole(oracleWallet.address)).to.be.revertedWithCustomError(paymaster, "AccessControlUnauthorizedAccount").withArgs(newOracleWallet.address, adminRole);
    });

    it("Random user can mint NFT using paymaster", async () => {
        const userWallet = Wallet.createRandom(getProvider());
        const userNonce = await userWallet.getNonce();

        const nftContract = await deployContract("ContentSignNFT", ["Click", "CLK", adminWallet.address], { wallet: adminWallet, silent: true, skipChecks: true }, adminNonce++);
        const minterRole = await nftContract.MINTER_ROLE();

        await nftContract.connect(adminWallet).grantRole(minterRole, userWallet.address, { nonce: adminNonce++ });
        expect(await nftContract.hasRole(minterRole, userWallet.address)).to.be.true;

        const paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
            type: "ApprovalBased",
            token: await nodl.getAddress(),
            minimalAllowance: ethers.toBigInt(0),
            innerInput: new Uint8Array(),
        });

        const tokenURI = "https://www.google.com";
        const tx = await nftContract.connect(userWallet).safeMint(userWallet.address, tokenURI, {
            nonce: userNonce,
            customData: {
                gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
                paymasterParams,
            },
        });
    });
});