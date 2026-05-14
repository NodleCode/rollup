import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { ethers } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";
import { deployContract } from "./utils";

dotenv.config({ path: ".env-test" });

/**
 * Deploys EnvelopeApprovalPaymaster on ZkSync Era.
 *
 * Path C support: lets users submit gasless `approve(envelopeVault, ...)` and
 * `setApprovalForAll(envelopeVault, ...)` txs against any token, gated entirely
 * by an EIP-712 grant signed off-chain by the operator. No per-token allowlist —
 * defense-in-depth comes from the per-tx ETH cap and the daily quota.
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY:   Private key for deployment (also default admin / withdrawer).
 *   - ENVELOPE_VAULT:              Address of the deployed Envelope vault — the only
 *                             allowed spender/operator for sponsored approvals.
 *
 * Optional environment variables (admin / signer):
 *   - ENVELOPE_PAYMASTER_ADMIN:           DEFAULT_ADMIN_ROLE. Defaults to deployer.
 *   - ENVELOPE_PAYMASTER_WITHDRAWER:      WITHDRAWER_ROLE. Defaults to deployer.
 *   - ENVELOPE_PAYMASTER_OPERATOR_SIGNER: EOA whose EIP-712 grant signatures are accepted.
 *                                         Defaults to ENVELOPE_MFA_AUTHORIZER if set, else deployer.
 *
 * Optional environment variables (config):
 *   - ENVELOPE_PAYMASTER_MAX_ETH_PER_TX:  Hard ceiling on wei sponsored per single tx.
 *                                         Default: 0.001 ETH (1e15 wei).
 *   - ENVELOPE_PAYMASTER_QUOTA:           Wei sponsorable per period. Default: 0.1 ETH.
 *   - ENVELOPE_PAYMASTER_PERIOD:          Period length in seconds. Default: 86400 (1 day).
 *   - ENVELOPE_PAYMASTER_FUNDING:         ETH (wei) to send to paymaster post-deploy. Default: 0.
 *   - ENVELOPE_PAYMASTER_INITIAL_OPERATORS: Comma-separated EOA list to seed as Mode B operators.
 *                                           Default: empty (Mode B dormant; admin can call setOperator later).
 *   - ENVELOPE_PAYMASTER_INITIAL_TARGETS:   Comma-separated contract list to seed as Mode B allowed targets.
 *                                           Default: ENVELOPE_VAULT (so operator can call the vault directly).
 *
 * Usage:
 *   yarn hardhat deploy-zksync \
 *     --script DeployEnvelopePaymaster.ts \
 *     --network zkSyncSepoliaTestnet
 */
module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const ZERO = ethers.ZeroAddress;

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const envelopeVault = process.env.ENVELOPE_VAULT;
  if (!envelopeVault || envelopeVault === ZERO) {
    throw new Error("ENVELOPE_VAULT env var is required (the deployed Envelope vault address)");
  }

  const admin = process.env.ENVELOPE_PAYMASTER_ADMIN ?? wallet.address;
  const withdrawer = process.env.ENVELOPE_PAYMASTER_WITHDRAWER ?? wallet.address;
  const operatorSigner =
    process.env.ENVELOPE_PAYMASTER_OPERATOR_SIGNER ??
    process.env.ENVELOPE_MFA_AUTHORIZER ??
    wallet.address;

  const maxEthPerTx = ethers.toBigInt(
    process.env.ENVELOPE_PAYMASTER_MAX_ETH_PER_TX ?? ethers.parseEther("0.001").toString(),
  );
  const quota = ethers.toBigInt(
    process.env.ENVELOPE_PAYMASTER_QUOTA ?? ethers.parseEther("0.1").toString(),
  );
  const period = BigInt(process.env.ENVELOPE_PAYMASTER_PERIOD ?? "86400");

  const funding = process.env.ENVELOPE_PAYMASTER_FUNDING
    ? ethers.toBigInt(process.env.ENVELOPE_PAYMASTER_FUNDING)
    : 0n;

  const initialOperators = (process.env.ENVELOPE_PAYMASTER_INITIAL_OPERATORS ?? "")
    .split(",")
    .map((a) => a.trim())
    .filter((a) => a.length > 0 && a !== ZERO);

  const initialTargets = (process.env.ENVELOPE_PAYMASTER_INITIAL_TARGETS ?? envelopeVault)
    .split(",")
    .map((a) => a.trim())
    .filter((a) => a.length > 0 && a !== ZERO);

  console.log("=== Deploying EnvelopeApprovalPaymaster on ZkSync ===");
  console.log("Network:           ", hre.network.name);
  console.log("Deployer:          ", wallet.address);
  console.log("Envelope Vault:    ", envelopeVault);
  console.log("Admin:             ", admin);
  console.log("Withdrawer:        ", withdrawer);
  console.log("Operator Signer:   ", operatorSigner);
  console.log("Max ETH per tx:    ", ethers.formatEther(maxEthPerTx), "ETH");
  console.log("Quota (wei):       ", quota.toString(), `(${ethers.formatEther(quota)} ETH)`);
  console.log("Period (seconds):  ", period.toString(), `(${Number(period) / 86400} days)`);
  console.log("Funding (wei):     ", funding.toString(), `(${ethers.formatEther(funding)} ETH)`);
  console.log("Mode B operators:  ", initialOperators.length > 0 ? initialOperators : "(none — seed later)");
  console.log("Mode B targets:    ", initialTargets);
  console.log("");

  const paymaster = await deployContract(deployer, "EnvelopeApprovalPaymaster", [
    admin,
    withdrawer,
    operatorSigner,
    envelopeVault,
    maxEthPerTx.toString(),
    quota.toString(),
    period.toString(),
  ]);
  const paymasterAddr = await paymaster.getAddress();

  if (funding > 0n) {
    console.log(`Funding paymaster with ${ethers.formatEther(funding)} ETH...`);
    const fundTx = await wallet.sendTransaction({ to: paymasterAddr, value: funding });
    await fundTx.wait();
    console.log(`  fund tx: ${fundTx.hash}`);
  }

  // Seed Mode B (only if deployer is the admin — otherwise admin must do this themselves).
  if (admin.toLowerCase() === wallet.address.toLowerCase()) {
    if (initialOperators.length > 0 || initialTargets.length > 0) {
      console.log("Seeding Mode B (operators + targets)...");
      for (const op of initialOperators) {
        const tx = await paymaster.setOperator(op, true);
        await tx.wait();
        console.log(`  setOperator(${op}, true) — tx: ${tx.hash}`);
      }
      for (const t of initialTargets) {
        const tx = await paymaster.setAllowedTarget(t, true);
        await tx.wait();
        console.log(`  setAllowedTarget(${t}, true) — tx: ${tx.hash}`);
      }
    }
  } else if (initialOperators.length > 0 || initialTargets.length > 0) {
    console.log(
      `Skipping Mode B seeding: admin (${admin}) is not the deployer; have the admin call setOperator / setAllowedTarget directly.`,
    );
  }

  console.log("");
  console.log("=== Deployment Complete ===");
  console.log("EnvelopeApprovalPaymaster:", paymasterAddr);
  console.log("Balance:", ethers.formatEther(await provider.getBalance(paymasterAddr)), "ETH");
  console.log("");

  console.log("=== Verifying Contract ===");
  try {
    await hre.run("verify:verify", {
      address: paymasterAddr,
      contract: "src/paymasters/EnvelopeApprovalPaymaster.sol:EnvelopeApprovalPaymaster",
      constructorArguments: [
        admin,
        withdrawer,
        operatorSigner,
        envelopeVault,
        maxEthPerTx.toString(),
        quota.toString(),
        period.toString(),
      ],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  console.log("");
  console.log("=== Add to .env-test ===");
  console.log(`ENVELOPE_PAYMASTER=${paymasterAddr}`);

  console.log("");
  console.log("=== Next steps ===");
  if (funding === 0n) {
    console.log(`- Fund the paymaster: wallet.sendTransaction({ to: ${paymasterAddr}, value: ... })`);
  }
  console.log(
    `- Operator backend: sign EIP-712 EnvelopeApprovalGrant(user, deadline, nonce) with the operatorSigner key (${operatorSigner})`,
  );
  console.log(
    `  Domain: { name: 'EnvelopeApprovalPaymaster', version: '1', chainId, verifyingContract: ${paymasterAddr} }`,
  );
};
