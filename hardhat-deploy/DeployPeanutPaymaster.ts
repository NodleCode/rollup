import { Provider, Wallet, utils } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";
import { deployContract } from "./utils";

dotenv.config({ path: ".env-test" });

/**
 * Deploys PeanutApprovalPaymaster on ZkSync Era.
 *
 * Path C support: lets users submit gasless `approve(peanutVault, ...)` and
 * `setApprovalForAll(peanutVault, ...)` txs against allowlisted tokens, gated by
 * an EIP-712 grant signed off-chain by the operator.
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY:   Private key for deployment (also default admin / withdrawer).
 *   - PEANUT_V4:              Address of the deployed PeanutV4 vault — used as the only
 *                             allowed spender/operator for sponsored approvals.
 *
 * Optional environment variables (admin / signer):
 *   - PEANUT_PAYMASTER_ADMIN:           DEFAULT_ADMIN_ROLE + ALLOWLIST_ADMIN_ROLE.
 *                                       Defaults to deployer.
 *   - PEANUT_PAYMASTER_WITHDRAWER:      WITHDRAWER_ROLE. Defaults to deployer.
 *   - PEANUT_PAYMASTER_OPERATOR_SIGNER: EOA whose EIP-712 grant signatures are accepted.
 *                                       Defaults to PEANUT_MFA_AUTHORIZER if set, else deployer.
 *
 * Optional environment variables (config):
 *   - PEANUT_PAYMASTER_QUOTA:    Wei sponsorable per period. Default: 0.1 ETH.
 *   - PEANUT_PAYMASTER_PERIOD:   Period length in seconds. Default: 86400 (1 day). Max: 2592000 (30 days).
 *   - PEANUT_PAYMASTER_FUNDING:  Amount of ETH to send to the paymaster post-deploy.
 *                                Default: 0 (must fund manually before use).
 *   - PEANUT_PAYMASTER_TOKENS:   Comma-separated token addresses to allowlist after deploy.
 *                                Default: none (must seed via addAllowedTokens).
 *
 * Usage:
 *   yarn hardhat deploy-zksync \
 *     --script DeployPeanutPaymaster.ts \
 *     --network zkSyncSepoliaTestnet
 */
module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const ZERO = ethers.ZeroAddress;

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const peanutVault = process.env.PEANUT_V4;
  if (!peanutVault || peanutVault === ZERO) {
    throw new Error("PEANUT_V4 env var is required (the deployed PeanutV4 vault address)");
  }

  const admin = process.env.PEANUT_PAYMASTER_ADMIN ?? wallet.address;
  const withdrawer = process.env.PEANUT_PAYMASTER_WITHDRAWER ?? wallet.address;
  const operatorSigner =
    process.env.PEANUT_PAYMASTER_OPERATOR_SIGNER ??
    process.env.PEANUT_MFA_AUTHORIZER ??
    wallet.address;

  const quota = ethers.toBigInt(
    process.env.PEANUT_PAYMASTER_QUOTA ?? ethers.parseEther("0.1").toString(),
  );
  const period = BigInt(process.env.PEANUT_PAYMASTER_PERIOD ?? "86400"); // 1 day

  const funding = process.env.PEANUT_PAYMASTER_FUNDING
    ? ethers.toBigInt(process.env.PEANUT_PAYMASTER_FUNDING)
    : 0n;

  const tokensToAllowlist = (process.env.PEANUT_PAYMASTER_TOKENS ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length > 0 && t !== ZERO);

  console.log("=== Deploying PeanutApprovalPaymaster on ZkSync ===");
  console.log("Network:           ", hre.network.name);
  console.log("Deployer:          ", wallet.address);
  console.log("Peanut Vault:      ", peanutVault);
  console.log("Admin:             ", admin);
  console.log("Withdrawer:        ", withdrawer);
  console.log("Operator Signer:   ", operatorSigner);
  console.log("Quota (wei):       ", quota.toString(), `(${ethers.formatEther(quota)} ETH)`);
  console.log("Period (seconds):  ", period.toString(), `(${Number(period) / 86400} days)`);
  console.log("Funding (wei):     ", funding.toString(), `(${ethers.formatEther(funding)} ETH)`);
  console.log("Tokens to allowlist:", tokensToAllowlist.length > 0 ? tokensToAllowlist : "(none — seed later)");
  console.log("");

  // 1. Deploy the paymaster.
  const paymaster = await deployContract(deployer, "PeanutApprovalPaymaster", [
    admin,
    withdrawer,
    operatorSigner,
    peanutVault,
    quota.toString(),
    period.toString(),
  ]);
  const paymasterAddr = await paymaster.getAddress();

  // 2. Fund the paymaster with ETH (so it can pay gas immediately).
  if (funding > 0n) {
    console.log(`Funding paymaster with ${ethers.formatEther(funding)} ETH...`);
    const fundTx = await wallet.sendTransaction({ to: paymasterAddr, value: funding });
    await fundTx.wait();
    console.log(`  fund tx: ${fundTx.hash}`);
  }

  // 3. Seed token allowlist (deployer must hold ALLOWLIST_ADMIN_ROLE).
  if (tokensToAllowlist.length > 0) {
    if (admin.toLowerCase() !== wallet.address.toLowerCase()) {
      console.log(
        `Skipping token seeding: admin (${admin}) is not the deployer; have the admin call addAllowedTokens directly.`,
      );
    } else {
      console.log("Allowlisting tokens...");
      const tx = await paymaster.addAllowedTokens(tokensToAllowlist);
      await tx.wait();
      console.log(`  tx: ${tx.hash}`);
    }
  }

  console.log("");
  console.log("=== Deployment Complete ===");
  console.log("PeanutApprovalPaymaster:", paymasterAddr);
  console.log("Balance:", ethers.formatEther(await provider.getBalance(paymasterAddr)), "ETH");
  console.log("");

  // 4. Verification.
  console.log("=== Verifying Contract ===");
  try {
    await hre.run("verify:verify", {
      address: paymasterAddr,
      contract: "src/paymasters/PeanutApprovalPaymaster.sol:PeanutApprovalPaymaster",
      constructorArguments: [
        admin,
        withdrawer,
        operatorSigner,
        peanutVault,
        quota.toString(),
        period.toString(),
      ],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  console.log("");
  console.log("=== Add to .env-test ===");
  console.log(`PEANUT_PAYMASTER=${paymasterAddr}`);

  console.log("");
  console.log("=== Next steps ===");
  if (funding === 0n) {
    console.log(
      `- Fund the paymaster: wallet.sendTransaction({ to: ${paymasterAddr}, value: ... })`,
    );
  }
  if (tokensToAllowlist.length === 0) {
    console.log(
      `- Seed token allowlist via PeanutApprovalPaymaster(${paymasterAddr}).addAllowedTokens([...])`,
    );
  }
  console.log(
    `- Operator backend: sign EIP-712 PeanutApprovalGrant(user, deadline, nonce) with the operatorSigner key (${operatorSigner})`,
  );
  console.log(
    "  Domain: { name: 'PeanutApprovalPaymaster', version: '1', chainId, verifyingContract: " +
      paymasterAddr +
      " }",
  );
};
