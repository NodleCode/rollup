import { expect } from "chai";
import { Contract, Wallet, utils, Provider } from "zksync-ethers";
import { ethers } from "ethers";
import {
  LOCAL_RICH_WALLETS,
  deployContract,
  getProvider,
  getWallet,
  getRandomWallet,
} from "../../deploy/utils";

/**
 *
 * @param errorSignature e.g. "AllowanceNotEnough(uint256,uint256)"
 * @returns the first 4 bytes (8 characters after '0x') of the hash as the selector
 */
function getErrorSelector(errorSignature: string): string {
  const hash = ethers.keccak256(Buffer.from(errorSignature, "utf-8"));
  return hash.slice(0, 10);
}

describe("Erc20Paymaster", function () {
  let provider: Provider;
  let paymaster: Contract;
  let paymasterAddress: string;
  let nodl: Contract;
  let nodlAddress: string;
  let nftContract: Contract;
  let adminWallet: Wallet;
  let oracleWallet: Wallet;
  let oracleRole: string;
  let adminRole: string;

  const initialFeePrice = 1n;

  before(async function () {
    provider = getProvider();

    adminWallet = getWallet(LOCAL_RICH_WALLETS[0].privateKey);
    oracleWallet = getWallet(LOCAL_RICH_WALLETS[1].privateKey);

    nodl = await deployContract(
      "NODL",
      [adminWallet.address, adminWallet.address],
      { wallet: adminWallet, silent: true, skipChecks: true },
    );
    await nodl.waitForDeployment();
    nodlAddress = await nodl.getAddress();

    paymaster = await deployContract(
      "Erc20Paymaster",
      [adminWallet.address, oracleWallet.address, nodlAddress, initialFeePrice],
      { wallet: adminWallet, silent: true, skipChecks: true },
    );
    await paymaster.waitForDeployment();
    paymasterAddress = await paymaster.getAddress();
    oracleRole = await paymaster.PRICE_ORACLE_ROLE();
    adminRole = await paymaster.DEFAULT_ADMIN_ROLE();

    const chargePaymaster = await adminWallet.transfer({
      to: paymasterAddress,
      amount: ethers.parseEther("0.5"),
    });
    await chargePaymaster.wait();
    expect(await provider.getBalance(paymasterAddress)).to.equal(
      ethers.parseEther("0.5"),
    );

    nftContract = await deployContract(
      "ContentSignNFT",
      ["Click", "CLK", adminWallet.address],
      { wallet: adminWallet, silent: true, skipChecks: true },
    );
    await nftContract.waitForDeployment();
  });

  it("Roles are set correctly", async () => {
    expect(await paymaster.hasRole(adminRole, adminWallet.address)).to.be.true;
    expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be
      .true;
  });

  it("Oracle can update fee price", async () => {
    let feePrice = await paymaster.feePrice();
    expect(feePrice).to.be.equal(initialFeePrice);

    const newFeePrice = 2;
    const updateFeePriceTx = await paymaster
      .connect(oracleWallet)
      .updateFeePrice(newFeePrice);
    await updateFeePriceTx.wait();

    feePrice = await paymaster.feePrice();
    expect(feePrice).to.be.equal(newFeePrice);
  });

  it("Non oracle cannot update fee price", async () => {
    const newFeePrice = 3;
    await expect(paymaster.connect(adminWallet).updateFeePrice(newFeePrice))
      .to.be.revertedWithCustomError(
        paymaster,
        "AccessControlUnauthorizedAccount",
      )
      .withArgs(adminWallet.address, oracleRole);
  });

  it("Admin can grant oracle role", async () => {
    const newOracleWallet = Wallet.createRandom();

    const tx = await paymaster
      .connect(adminWallet)
      .grantPriceOracleRole(newOracleWallet.address);
    await tx.wait();

    expect(await paymaster.hasRole(oracleRole, newOracleWallet.address)).to.be
      .true;
    expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be
      .true;
  });

  it("Admin can revoke oracle role", async () => {
    const revokeTx = await paymaster
      .connect(adminWallet)
      .revokePriceOracleRole(oracleWallet.address);
    await revokeTx.wait();

    expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be
      .false;

    // grant the role back after testing revoke
    const grantBackTx = await paymaster
      .connect(adminWallet)
      .grantPriceOracleRole(oracleWallet.address);
    await grantBackTx.wait();
    expect(await paymaster.hasRole(oracleRole, oracleWallet.address)).to.be
      .true;
  });

  it("Non Admin cannot grant or revoke roles", async () => {
    const newOracleWallet = getRandomWallet();
    await expect(
      paymaster
        .connect(oracleWallet)
        .grantPriceOracleRole(newOracleWallet.address),
    )
      .to.be.revertedWithCustomError(
        paymaster,
        "AccessControlUnauthorizedAccount",
      )
      .withArgs(oracleWallet.address, adminRole);
    await expect(
      paymaster
        .connect(newOracleWallet)
        .revokePriceOracleRole(oracleWallet.address),
    )
      .to.be.revertedWithCustomError(
        paymaster,
        "AccessControlUnauthorizedAccount",
      )
      .withArgs(newOracleWallet.address, adminRole);
  });

  it("Random user can mint NFT using paymaster", async () => {
    const userWallet = getRandomWallet();
    expect(await provider.getBalance(userWallet.address)).to.equal(0n);

    const gasLimit = 400000n;
    const gasPrice = await provider.getGasPrice();
    const requiredEth = gasLimit * gasPrice;
    const feePrice = await paymaster.feePrice();
    const requiredNodl = requiredEth * feePrice;

    const nodlMintTx = await nodl
      .connect(adminWallet)
      .mint(userWallet.address, requiredNodl);
    await nodlMintTx.wait();

    const userNodlBalance = ethers.toBigInt(
      await nodl.balanceOf(userWallet.address),
    );
    expect(userNodlBalance).to.equal(requiredNodl);

    const minterRole = await nftContract.MINTER_ROLE();
    const grantRoleTx = await nftContract
      .connect(adminWallet)
      .grantRole(minterRole, userWallet.address);
    await grantRoleTx.wait();

    expect(await nftContract.hasRole(minterRole, userWallet.address)).to.be
      .true;

    const nextNFTTokenId = await nftContract.nextTokenId();
    const tokenURI =
      "https://ipfs.io/ipfs/QmXuYh3h1e8zZ5r9w8X4LZQv3B7qQ9mZQz5o4Jr2A4FzY6";
    const safeMintTx = await nftContract
      .connect(userWallet)
      .safeMint(userWallet.address, tokenURI, {
        gasLimit,
        customData: {
          gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
          paymasterParams: utils.getPaymasterParams(paymasterAddress, {
            type: "ApprovalBased",
            token: nodlAddress,
            minimalAllowance: requiredNodl,
            innerInput: new Uint8Array(),
          }),
        },
      });
    await safeMintTx.wait();

    expect(await nftContract.ownerOf(nextNFTTokenId)).to.equal(
      userWallet.address,
    );
    expect(await nftContract.tokenURI(nextNFTTokenId)).to.equal(tokenURI);

    const mintNodlCost =
      userNodlBalance - (await nodl.balanceOf(userWallet.address));
    expect(Number(mintNodlCost)).to.lessThanOrEqual(Number(requiredNodl));
  });

  it("User cannot use paymaster with insufficient allowance", async () => {
    const userWallet = getRandomWallet();
    const gasLimit = 400000n;
    const gasPrice = await provider.getGasPrice();
    const requiredEth = gasLimit * gasPrice;
    const feePrice = await paymaster.feePrice();
    const requiredNodl = requiredEth * feePrice;
    const insufficientNodlAllowance = requiredNodl - 1n;

    const nodlMintTx = await nodl
      .connect(adminWallet)
      .mint(userWallet.address, requiredNodl);
    await nodlMintTx.wait();

    const minterRole = await nftContract.MINTER_ROLE();
    const grantRoleTx = await nftContract
      .connect(adminWallet)
      .grantRole(minterRole, userWallet.address);
    await grantRoleTx.wait();

    const expectedErrorSelector = getErrorSelector(
      "AllowanceNotEnough(uint256,uint256)",
    );
    const tokenURI =
      "https://ipfs.io/ipfs/QmXuYh3h1e8zZ5r9w8X4LZQv3B7qQ9mZQz5o4Jr2A4FzY6";
    await expect(
      nftContract.connect(userWallet).safeMint(userWallet.address, tokenURI, {
        gasLimit,
        customData: {
          gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
          paymasterParams: utils.getPaymasterParams(paymasterAddress, {
            type: "ApprovalBased",
            token: nodlAddress,
            minimalAllowance: insufficientNodlAllowance,
            innerInput: new Uint8Array(),
          }),
        },
      }),
    )
      .to.be.rejected.and.eventually.have.property("message")
      .that.matches(
        new RegExp(
          `error.*Paymaster.*function_selector\\s*=\\s*${expectedErrorSelector}`,
        ),
      );
  });

  it("User cannot use paymaster with insufficient balance", async () => {
    const userWallet = getRandomWallet();
    const gasLimit = 400000n;
    const gasPrice = await provider.getGasPrice();
    const requiredEth = gasLimit * gasPrice;
    const feePrice = await paymaster.feePrice();
    const requiredNodl = requiredEth * feePrice;
    const insufficientUserBalance = requiredNodl - 1n;

    const nodlMintTx = await nodl
      .connect(adminWallet)
      .mint(userWallet.address, insufficientUserBalance);
    await nodlMintTx.wait();

    const minterRole = await nftContract.MINTER_ROLE();
    const grantRoleTx = await nftContract
      .connect(adminWallet)
      .grantRole(minterRole, userWallet.address);
    await grantRoleTx.wait();

    const expectedErrorSelector = getErrorSelector("FeeTransferFailed(bytes)");
    const tokenURI =
      "https://ipfs.io/ipfs/QmXuYh3h1e8zZ5r9w8X4LZQv3B7qQ9mZQz5o4Jr2A4FzY6";
    await expect(
      nftContract.connect(userWallet).safeMint(userWallet.address, tokenURI, {
        gasLimit,
        customData: {
          gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
          paymasterParams: utils.getPaymasterParams(paymasterAddress, {
            type: "ApprovalBased",
            token: nodlAddress,
            minimalAllowance: requiredNodl,
            innerInput: new Uint8Array(),
          }),
        },
      }),
    )
      .to.be.rejected.and.eventually.have.property("message")
      .that.matches(
        new RegExp(
          `error.*Paymaster.*function_selector\\s*=\\s*${expectedErrorSelector}`,
        ),
      );
  });

  it("Transaction fails if fee is too high", async () => {
    const userWallet = getRandomWallet();
    const highGasLimit =
      (await provider.getBlock("latest").then((block) => block.gasLimit)) / 2n;
    const largestPossibleNodlBalance =
      (await nodl.cap()) - (await nodl.totalSupply());

    const nodlMintTx = await nodl
      .connect(adminWallet)
      .mint(userWallet.address, largestPossibleNodlBalance);
    await nodlMintTx.wait();

    const highFeePrice = 2n ** 256n - 1n;
    const updateFeePriceTx = await paymaster
      .connect(oracleWallet)
      .updateFeePrice(highFeePrice);
    await updateFeePriceTx.wait();

    const feePrice = await paymaster.feePrice();
    expect(feePrice).to.be.equal(highFeePrice);

    const minterRole = await nftContract.MINTER_ROLE();
    const grantRoleTx = await nftContract
      .connect(adminWallet)
      .grantRole(minterRole, userWallet.address);
    await grantRoleTx.wait();

    const expectedErrorSelector = getErrorSelector(
      "FeeTooHigh(uint256,uint256)",
    );
    const tokenURI =
      "https://ipfs.io/ipfs/QmXuYh3h1e8zZ5r9w8X4LZQv3B7qQ9mZQz5o4Jr2A4FzY6";
    await expect(
      nftContract.connect(userWallet).safeMint(userWallet.address, tokenURI, {
        gasLimit: highGasLimit,
        customData: {
          gasPerPubdata: utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
          paymasterParams: utils.getPaymasterParams(paymasterAddress, {
            type: "ApprovalBased",
            token: nodlAddress,
            minimalAllowance: largestPossibleNodlBalance,
            innerInput: new Uint8Array(),
          }),
        },
      }),
    )
      .to.be.rejected.and.eventually.have.property("message")
      .that.matches(
        new RegExp(
          `error.*Paymaster.*function_selector\\s*=\\s*${expectedErrorSelector}`,
        ),
      );
  });
});
