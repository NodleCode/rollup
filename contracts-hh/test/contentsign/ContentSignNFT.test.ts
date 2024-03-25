import { expect } from "chai";
import { Contract, Wallet } from "zksync-ethers";
import {
  getWallet,
  deployContract,
  LOCAL_RICH_WALLETS,
} from "../../deploy/utils";

describe("ContentSignNFT", function () {
  let paymasterContract: Contract;
  let tokenContract: Contract;
  let ownerWallet: Wallet;
  let userWallet: Wallet;

  before(async function () {
    ownerWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
    userWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);

    paymasterContract = await deployContract(
      "WhitelistPaymaster",
      [ownerWallet.address, ownerWallet.address, ownerWallet.address, []],
      { wallet: ownerWallet, silent: true, skipChecks: true },
    );

    tokenContract = await deployContract(
      "ContentSignNFT",
      ["Mock", "MCK", await paymasterContract.getAddress()],
      { wallet: ownerWallet, silent: true, skipChecks: true },
    );

    const contractTx = await paymasterContract.addWhitelistedContracts([
      await tokenContract.getAddress(),
    ]);
    await contractTx.wait();
    const userTx = await paymasterContract.addWhitelistedUsers([
      userWallet.address,
    ]);
    await userTx.wait();
  });

  it("Set the right metadata", async function () {
    expect(await tokenContract.name()).to.equal("Mock");
    expect(await tokenContract.symbol()).to.equal("MCK");
  });

  it("Should mint token", async function () {
    const tokenURI = "https://example.com";

    const mintTx = await tokenContract
      .connect(userWallet)
      .safeMint(userWallet.address, tokenURI);
    await mintTx.wait();

    const tokenURIResult = await tokenContract.tokenURI(0);

    expect(tokenURIResult).to.equal(tokenURI);
  });

  it("Non minter cannot mint token", async function () {
    const tokenURI = "https://example.com";

    await expect(
      tokenContract.connect(ownerWallet).safeMint(userWallet.address, tokenURI),
    ).to.be.revertedWithCustomError(tokenContract, "UserIsNotWhitelisted");
  });
});
