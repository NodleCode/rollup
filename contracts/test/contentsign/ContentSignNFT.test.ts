import { expect } from 'chai';
import { Contract, Wallet } from "zksync-ethers";
import { getWallet, deployContract, LOCAL_RICH_WALLETS } from '../../deploy/utils';

describe("ContentSignNFT", function () {
  let tokenContract: Contract;
  let ownerWallet: Wallet;
  let userWallet: Wallet;

  before(async function () {
    ownerWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
    userWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);

    tokenContract = await deployContract("ContentSignNFT", ["Mock", "MCK", ownerWallet.address], { wallet: ownerWallet, silent: true, skipChecks: true });
  });

  it("Set the right metadata", async function () {
    expect(await tokenContract.name()).to.equal("Mock");
    expect(await tokenContract.symbol()).to.equal("MCK");
  });

  it("Should mint token", async function () {
    const tokenURI = "https://example.com";

    const mintTx = await tokenContract.safeMint(userWallet.address, tokenURI);
    await mintTx.wait();
    const tokenURIResult = await tokenContract.tokenURI(0);

    expect(tokenURIResult).to.equal(tokenURI);
  });

  it("Non minter cannot mint token", async function () {
    const tokenURI = "https://example.com";

    const minterRole = await tokenContract.MINTER_ROLE();
    await expect(
      tokenContract
        .connect(userWallet)
        .safeMint(userWallet.address, tokenURI)
    ).to.be
      .revertedWithCustomError(tokenContract, "AccessControlUnauthorizedAccount")
      .withArgs(userWallet.address, minterRole);
  });
});