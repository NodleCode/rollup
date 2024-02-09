import { expect } from 'chai';
import { Contract, Wallet } from "zksync-ethers";
import { getWallet, deployContract, LOCAL_RICH_WALLETS } from '../deploy/utils';
import * as ethers from "ethers";

describe("NODL", function () {
  let tokenContract: Contract;
  let ownerWallet: Wallet;
  let userWallet: Wallet;
  const mintAmount = 1000n;

  before(async function () {
    ownerWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
    userWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);

    tokenContract = await deployContract("NODL", [ownerWallet.address, ownerWallet.address], { wallet: ownerWallet, silent: true, skipChecks: true });
    await tokenContract.waitForDeployment();
  });

  it("Should be deployed with no supply", async function () {
    const initialSupply = await tokenContract.totalSupply();
    expect(initialSupply.toString()).to.equal("0");
  });

  it("Should be mintable", async () => {
    const balanceBefore = await tokenContract.balanceOf(userWallet.address);
    const initialSupply = await tokenContract.totalSupply();

    const minTx = await tokenContract.connect(ownerWallet).mint(userWallet.address, mintAmount);
    await minTx.wait();

    const balanceAfter = await tokenContract.balanceOf(userWallet.address);
    expect(balanceAfter).to.equal(balanceBefore + mintAmount);

    const finalSupply = await tokenContract.totalSupply();
    expect(finalSupply).to.equal(initialSupply + mintAmount);
  });

  it("Should be burnable", async () => {
    const balanceBefore = await tokenContract.balanceOf(userWallet.address);
    const initialSupply = await tokenContract.totalSupply();
    const burnAmount = mintAmount/2n;

    const userBurnTx = await tokenContract.connect(userWallet).burn(burnAmount);
    await userBurnTx.wait();

    const balanceAfterUserBurn = await tokenContract.balanceOf(userWallet.address);
    expect(balanceAfterUserBurn).to.equal(balanceBefore - burnAmount);
    const supplyAfterUserBurn = await tokenContract.totalSupply();
    expect(supplyAfterUserBurn).to.equal(initialSupply - burnAmount);

    const userApproveTx = await tokenContract.connect(userWallet).approve(ownerWallet.address, burnAmount);
    await userApproveTx.wait();

    const approvedBurnTx = await tokenContract.connect(ownerWallet).burnFrom(userWallet.address, burnAmount);
    await approvedBurnTx.wait();

    const balanceAfterApprovedBurn = await tokenContract.balanceOf(userWallet.address);
    expect(balanceAfterApprovedBurn).to.equal(balanceBefore - mintAmount);

    const supplyAfterApprovedBurn = await tokenContract.totalSupply();
    expect(supplyAfterApprovedBurn).to.equal(initialSupply - mintAmount);
  });

  it("Has a max supply of 21 billion", async () => {
    const maxSupply = ethers.parseUnits("21000000000", 11);
    const cap = await tokenContract.cap();
    expect(cap).to.equal(maxSupply);
  });

  it("Cannot mint above max supply", async () => {
    const cap = await tokenContract.cap();
    const currentSupply = await tokenContract.totalSupply();

    const maxMint = cap - currentSupply;
    const mintAllTx = await tokenContract.connect(ownerWallet).mint(userWallet.address, maxMint);
    await mintAllTx.wait();

    expect(await tokenContract.balanceOf(userWallet.address)).to.equal(maxMint);
    expect(await tokenContract.totalSupply()).to.equal(cap);

    const mintAboveCapTx = tokenContract.connect(ownerWallet).mint(userWallet.address, 1);
    await expect(mintAboveCapTx).to.be.revertedWithCustomError(tokenContract, "ERC20ExceededCap").withArgs(cap + 1n, cap);
  });
});