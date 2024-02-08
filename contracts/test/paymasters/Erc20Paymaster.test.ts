import { expect } from 'chai';
import { Contract, Wallet, utils } from "zksync-ethers";
import { ethers } from "ethers";
import { LOCAL_RICH_WALLETS, deployContract, getProvider, getWallet} from '../../deploy/utils';

describe("Erc20Paymaster", function () {
    let paymaster: Contract;
    let paymasterAddress: string;
    let nodl: Contract;
    let nodlAddress: string;
    let adminWallet: Wallet;
    let oracleWallet: Wallet;
    let oracleRole: string;
    let adminRole: string;
    let adminNonce: number;

    const initialFeePrice = 1n;

    before(async function () {
        adminWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
        oracleWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);
        
        adminNonce = await adminWallet.getNonce(); 

        nodl = await deployContract("NODL", [adminWallet.address, adminWallet.address], { wallet: adminWallet, silent: true, skipChecks: true }, adminNonce++);
        await nodl.waitForDeployment();
        nodlAddress = await nodl.getAddress();

        paymaster = await deployContract("Erc20Paymaster", [adminWallet.address, oracleWallet.address, nodlAddress, initialFeePrice], { wallet: adminWallet, silent: true, skipChecks: true }, adminNonce++);
        await paymaster.waitForDeployment();
        paymasterAddress = await paymaster.getAddress();
        oracleRole = await paymaster.PRICE_ORACLE_ROLE();
        adminRole = await paymaster.DEFAULT_ADMIN_ROLE();
        
        const chargePaymaster = await adminWallet.transfer( {to: paymasterAddress, amount: ethers.parseEther("0.5"), overrides: {nonce: adminNonce++} });
        await chargePaymaster.wait();    
        expect(await getProvider().getBalance(paymasterAddress)).to.equal(ethers.parseEther("0.5"));
    });

    it("Roles are set correctly", async () => {
        expect(await paymaster.hasRole(adminRole, adminWallet.address)).to.be.true;
        expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be.true;
    });

    it("Oracle can update fee price", async () => {
        let feePrice = await paymaster.feePrice();
        expect(feePrice).to.be.equal(initialFeePrice);

        const newFeePrice = 2;
        const updateFeePriceTx = await paymaster.connect(oracleWallet).updateFeePrice(newFeePrice);
        await updateFeePriceTx.wait();
        
        feePrice = await paymaster.feePrice();
        expect(feePrice).to.be.equal(newFeePrice);
    });

    it("None oracle can't update fee price", async () => {
        const newFeePrice = 3;
        await expect(paymaster.connect(adminWallet).updateFeePrice(newFeePrice, { nonce: adminNonce })).to.be.revertedWithCustomError(paymaster, "AccessControlUnauthorizedAccount").withArgs(adminWallet.address, oracleRole);
    });

    it("Admin can grant oracle role", async () => {       
        const newOracleWallet = Wallet.createRandom();
        
        const tx = await paymaster.connect(adminWallet).grantPriceOracleRole(newOracleWallet.address, { nonce: adminNonce++ });
        await tx.wait();
        
        expect(await paymaster.hasRole(oracleRole, newOracleWallet.address)).to.be.true;
        expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be.true;
    });

    it("Admin can revoke oracle role", async () => {
        const tx = await paymaster.connect(adminWallet).revokePriceOracleRole(oracleWallet.address, { nonce: adminNonce++ });
        await tx.wait();

        expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be.false;
    });

    it("Non Admin cannot grant or revoke roles", async () => {  
        const newOracleWallet = Wallet.createRandom(getProvider());
        await expect(paymaster.connect(oracleWallet).grantPriceOracleRole(newOracleWallet.address)).to.be.revertedWithCustomError(paymaster, "AccessControlUnauthorizedAccount").withArgs(oracleWallet.address, adminRole);
        await expect(paymaster.connect(newOracleWallet).revokePriceOracleRole(oracleWallet.address)).to.be.revertedWithCustomError(paymaster, "AccessControlUnauthorizedAccount").withArgs(newOracleWallet.address, adminRole);
    });

    it("Random user can mint NFT using paymaster", async () => {
        const provider = getProvider();

        const userWallet= getWallet();
        expect(await provider.getBalance(userWallet.address)).to.equal(0n);

        const gasLimit = 400000n;
        const gasPrice = await provider.getGasPrice();
        const requiredEth = gasLimit * gasPrice;
        const requiredNodl = requiredEth * initialFeePrice;
        const nodlMintTx = await nodl.connect(adminWallet).mint(userWallet.address, requiredNodl, { nonce: adminNonce++ });
        await nodlMintTx.wait();

        const userNodlBalance = ethers.toBigInt(await nodl.balanceOf(userWallet.address));
        expect(userNodlBalance).to.equal(requiredNodl);

        const nftContract = await deployContract("ContentSignNFT", ["Click", "CLK", adminWallet.address], { wallet: adminWallet, silent: true, skipChecks: true }, adminNonce++);
        await nftContract.waitForDeployment();

        const minterRole = await nftContract.MINTER_ROLE();
        const grantRoleTx = await nftContract.connect(adminWallet).grantRole(minterRole, userWallet.address, { nonce: adminNonce++ });
        await grantRoleTx.wait();

        expect(await nftContract.hasRole(minterRole, userWallet.address)).to.be.true;

        const nodlAllowance = requiredNodl;

        // User doesn't need to approve the paymaster, it will be done automatically
        expect(await nodl.allowance(userWallet.address, paymasterAddress)).to.equal(0);

        const nextNFTTokenId = await nftContract.nextTokenId();
        const tokenURI = "https://ipfs.io/ipfs/QmXuYh3h1e8zZ5r9w8X4LZQv3B7qQ9mZQz5o4Jr2A4FzY6";
        const safeMintTx = await nftContract.connect(userWallet).safeMint(userWallet.address, tokenURI, {
            nonce: 0,
            gasLimit,
            customData: {
                gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
                paymasterParams: utils.getPaymasterParams(paymasterAddress, {
                    type: "ApprovalBased",
                    token: nodlAddress,
                    minimalAllowance: nodlAllowance,
                    innerInput: new Uint8Array(),
                }),
            },
        });
        await safeMintTx.wait();

        expect(await nftContract.ownerOf(nextNFTTokenId)).to.equal(userWallet.address);
        expect(await nftContract.tokenURI(nextNFTTokenId)).to.equal(tokenURI);

        const mintNodlCost = userNodlBalance - await nodl.balanceOf(userWallet.address);
        expect(Number(mintNodlCost)).to.lessThanOrEqual(Number(nodlAllowance));
    });
});