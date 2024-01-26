import { expect } from 'chai';
import { Contract, Provider, Wallet, utils } from "zksync-ethers";
import * as ethers from "ethers";
import { setupEnv } from './helpers';
import { LOCAL_RICH_WALLETS, deployContract, getWallet, getProvider } from '../../deploy/utils';

describe("Erc20Paymaster", function () {
    let paymaster: Contract;
    let nodl: Contract;

    let adminWallet: Wallet;
    let oracleWallet: Wallet;

    let provider: Provider;

    const initialFeePrice = 1; // Means 1 nodle per 1 wei

    before(async function () {
        const emptyWallet = Wallet.createRandom();
        provider = getProvider();

        adminWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
        oracleWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);
        
        let nonce = await adminWallet.getNonce(); 

        nodl = await deployContract("NODL", [adminWallet.address, adminWallet.address], { wallet: adminWallet, silent: true, skipChecks: true }, nonce++);
        const nodlAddress = await nodl.getAddress();

        paymaster = await deployContract("Erc20Paymaster", [adminWallet.address, oracleWallet.address, nodlAddress, initialFeePrice], { wallet: adminWallet, silent: true, skipChecks: true }, nonce++);
        const paymasterAddress = await paymaster.getAddress();
        
        const transactionResponse = await adminWallet.sendTransaction({ to: paymasterAddress, value: ethers.parseEther("1"), nonce: nonce++ });
        await transactionResponse.wait();    
    });

    it("Oracle role is set correctly", async () => {
        const oracleRole = await paymaster.PRICE_ORACLE_ROLE();
        expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be.true;
    });
});