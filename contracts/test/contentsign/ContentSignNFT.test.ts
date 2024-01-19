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

    tokenContract = await deployContract("ContentSignNFT", [ownerWallet.address, ownerWallet.address], { wallet: ownerWallet, silent: true, skipChecks: true });
  });

  it("Should mint token", async function () {
    const tokenURI = "https://example.com";

    await tokenContract.safeMint(userWallet.address, tokenURI);
    const tokenURIResult = await tokenContract.tokenURI(0);

    expect(tokenURIResult).to.equal(tokenURI);
  });

  it("Non minter cannot mint token", async function () {
    const tokenURI = "https://example.com";

    try {
        await tokenContract.connect(userWallet).safeMint(userWallet.address, tokenURI);
        expect.fail("Should have reverted");
    } catch (e) {
        expect(e.message).to.contain("execution reverted");
    }
  });
});