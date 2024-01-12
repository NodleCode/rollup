import { expect } from 'chai';
import { Contract, Wallet } from "zksync-ethers";
import { getWallet, deployContract, LOCAL_RICH_WALLETS } from '../deploy/utils';
import * as ethers from "ethers";

describe("NODL", function () {
  let tokenContract: Contract;
  let ownerWallet: Wallet;
  let userWallet: Wallet;

  before(async function () {
    ownerWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
    userWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);

    tokenContract = await deployContract("NODL", [ownerWallet.address, ownerWallet.address], { wallet: ownerWallet, silent: true, skipChecks: true });
  });

  it("Should be deployed with no supply", async function () {
    const initialSupply = await tokenContract.totalSupply();
    expect(initialSupply.toString()).to.equal("0");
  });

  it("Should be mintable", async () => {
    const mintAmount = ethers.parseEther("1000");
    const initialSupply = await tokenContract.totalSupply();
    await tokenContract.mint(userWallet.address, mintAmount);

    const balance = await tokenContract.balanceOf(userWallet.address);
    expect(balance.toString()).to.equal(mintAmount.toString());

    const finalSupply = await tokenContract.totalSupply();
    expect(finalSupply).to.equal(initialSupply + mintAmount);
  });
});