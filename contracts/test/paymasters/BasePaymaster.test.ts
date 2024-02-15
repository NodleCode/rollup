import { expect } from "chai";
import { Contract, Provider, Wallet, utils } from "zksync-ethers";
import * as ethers from "ethers";
import { setupEnv } from "./helpers";
import {
  deployContract,
  getProvider,
  getRandomWallet,
} from "../../deploy/utils";

describe("BasePaymaster", function () {
  let paymaster: Contract;
  let flag: Contract;
  let nodl: Contract;

  let adminWallet: Wallet;
  let withdrawerWallet: Wallet;
  let sponsorWallet: Wallet;
  let userWallet: Wallet;

  let provider: Provider;

  before(async function () {
    const result = await setupEnv("MockPaymaster");
    paymaster = result.paymaster;
    adminWallet = result.adminWallet;
    withdrawerWallet = result.withdrawerWallet;
    sponsorWallet = result.sponsorWallet;

    userWallet = getRandomWallet();
    provider = getProvider();

    // using the admin or sponsor wallet to deploy seem to have us run into
    // a nonce management bug in zksync-ethers
    flag = await deployContract("MockFlag", [], {
      wallet: withdrawerWallet,
      silent: true,
      skipChecks: true,
    });
    nodl = await deployContract(
      "NODL",
      [adminWallet.address, adminWallet.address],
      { wallet: withdrawerWallet, silent: true, skipChecks: true },
    );
  });

  async function executePaymasterTransaction(
    user: Wallet,
    type: "General" | "ApprovalBased",
    flagValue: string = "flag captured",
  ) {
    let paymasterParams;
    if (type === "General") {
      paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
        type: "General",
        innerInput: new Uint8Array(),
      });
    } else {
      paymasterParams = utils.getPaymasterParams(await paymaster.getAddress(), {
        type: "ApprovalBased",
        token: await nodl.getAddress(),
        minimalAllowance: ethers.toBigInt(0),
        innerInput: new Uint8Array(),
      });
    }

    const flagTx = await flag.connect(user).setFlag(flagValue, {
      customData: {
        gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
        paymasterParams,
      },
    });
    await flagTx.wait();

    expect(await flag.flag()).to.equal(flagValue);
  }

  it("Can withdraw excess ETH", async () => {
    const balancePaymasterBefore = await provider.getBalance(
      await paymaster.getAddress(),
    );
    const balanceSponsorBefore = await provider.getBalance(
      sponsorWallet.address,
    );

    const withdrawValue = ethers.parseEther("0.5");

    // we withdraw to the sponsor wallet so we can compute the balance changes
    // without having to handle the tx fees
    const tx = await paymaster
      .connect(withdrawerWallet)
      .withdraw(sponsorWallet.address, withdrawValue);
    await tx.wait();

    // BUG: the RPC is not quite up to date with the withdrawal tx (ie. there is some lag)
    // so we trigger another tx to force a refresh
    await flag.connect(adminWallet).setFlag("bug fix delay");

    expect(await provider.getBalance(sponsorWallet.address)).to.equal(
      balanceSponsorBefore + withdrawValue,
    );
    expect(await provider.getBalance(await paymaster.getAddress())).to.equal(
      balancePaymasterBefore - withdrawValue,
    );
  });

  it("Works as a paymaster", async () => {
    // no eth to pay for fees
    expect(await provider.getBalance(userWallet.address)).to.equal(
      ethers.toBigInt(0),
    );

    // yet it works
    await executePaymasterTransaction(userWallet, "General", "flag captured 1");
    await executePaymasterTransaction(
      userWallet,
      "ApprovalBased",
      "flag captured 2",
    );
  });

  it("Fails if not enough ETH", async () => {
    // withdraw all the ETH
    const toWithdraw = await provider.getBalance(await paymaster.getAddress());
    const tx = await paymaster
      .connect(withdrawerWallet)
      .withdraw(withdrawerWallet.address, toWithdraw);
    await tx.wait();

    // paymaster cannot pay for txs anymore
    await expect(executePaymasterTransaction(userWallet, "General")).to.be
      .reverted;

    // sanity checks: make sure the paymaster balance was emptied
    // not done earlier as it sounds like the RPC is not quite up
    // to date with the withdrawal tx (ie. there is some lag)
    const paymasterBalance = await provider.getBalance(
      await paymaster.getAddress(),
    );
    expect(paymasterBalance).to.equal(ethers.toBigInt(0));
  });

  it("Sets correct roles", async () => {
    const withdrawerRole = await paymaster.WITHDRAWER_ROLE();
    const adminRole = await paymaster.DEFAULT_ADMIN_ROLE();

    expect(await paymaster.hasRole(withdrawerRole, withdrawerWallet.address)).to
      .be.true;
    expect(await paymaster.hasRole(adminRole, adminWallet.address)).to.be.true;
  });
});
