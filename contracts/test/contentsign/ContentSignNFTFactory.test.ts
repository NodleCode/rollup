import { expect } from 'chai';
import { Contract, Wallet, utils } from "zksync-ethers";
import { getWallet, deployContract, LOCAL_RICH_WALLETS } from '../../deploy/utils';
import { Deployer } from '@matterlabs/hardhat-zksync-deploy';
import * as ethers from "ethers";
import * as hre from "hardhat";

describe("ContentSignNFTFactory", function () {
    let wallet: Wallet;
    let factory: Contract;

    before(async function () {
        wallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
        factory = await deployContract("ContentSignNFTFactory", [], { silent: true, skipChecks: true });
    });

    it("Should deploy contract", async function () {
        const salt = ethers.ZeroHash;

        const tx = await factory.deployContentSignNFT(salt, wallet.address, wallet.address);
        await tx.wait();

        const deployer = new Deployer(hre, wallet);
        const artifact = await deployer.loadArtifact("ContentSignNFT");

        const abiCoder = new ethers.AbiCoder();
        const contractAddress = utils.create2Address(
            await factory.getAddress(),
            utils.hashBytecode(artifact.bytecode),
            salt,
            abiCoder.encode(["address", "address"], [wallet.address, wallet.address])
        );

        const nft = new Contract(contractAddress, artifact.abi, wallet);
        const name = await nft.name();
        const symbol = await nft.symbol();

        expect(name).to.equal("ContentSign");
        expect(symbol).to.equal("CSN");
        expect(await nft.hasRole(await nft.DEFAULT_ADMIN_ROLE(), wallet.address)).to.equal(true);
        expect(await nft.hasRole(await nft.MINTER_ROLE(), wallet.address)).to.equal(true);
    });
});