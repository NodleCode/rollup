import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";
import { deployContract } from "./utils";

/**
 * Deploys the Envelope (vendored Peanut V4.4) suite on ZkSync Era.
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment.
 *
 * Optional environment variables:
 *   - ENVELOPE_MFA_AUTHORIZER: Address authorized to sign MFA withdraw approvals.
 *                            Defaults to 0x0 (MFA disabled — claimWithMFA reverts).
 *                            Set to your backend signer for production MFA/fee authorizations.
 *   - ENVELOPE_OWNER:          Owner/fee withdrawer. Defaults to deployer.
 *   - ENVELOPE_FEE_TOKEN:      ERC20 token used for service/gasless fees (e.g. NODL).
 *                            Defaults to 0x0 (non-zero fee authorizations disabled).
 *   - ENVELOPE_DEPLOY_PAYMASTER: "true"|"false". Default "false". Deploys EnvelopePaymaster.
 *   - ENVELOPE_PAYMASTER_ADMIN: Admin for EnvelopePaymaster. Defaults to deployer.
 *   - ENVELOPE_PAYMASTER_WITHDRAWER: ETH withdrawer for EnvelopePaymaster. Defaults to deployer.
 *
 * Usage:
 *   yarn hardhat deploy-zksync \
 *     --script DeployEnvelope.ts \
 *     --network zkSyncSepoliaTestnet
 */
module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const ZERO = "0x0000000000000000000000000000000000000000";

  // Load .env-prod for mainnet, .env-test otherwise. Must key off
  // hre.network.name: process.env.HARDHAT_NETWORK is NOT set when the network
  // comes from the --network CLI flag (deploy-zksync loads this script
  // in-process), so an env-var check would silently pick .env-test on mainnet.
  const envFile =
    hre.network.name === "zkSyncMainnet" ? ".env-prod" : ".env-test";
  dotenv.config({ path: envFile });

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const mfaAuthorizer = process.env.ENVELOPE_MFA_AUTHORIZER ?? ZERO;
  const envelopeOwner = process.env.ENVELOPE_OWNER ?? wallet.address;
  const feeToken = process.env.ENVELOPE_FEE_TOKEN ?? ZERO;
  const deployPaymaster =
    (process.env.ENVELOPE_DEPLOY_PAYMASTER ?? "false").toLowerCase() === "true";
  const paymasterAdmin = process.env.ENVELOPE_PAYMASTER_ADMIN ?? wallet.address;
  const paymasterWithdrawer =
    process.env.ENVELOPE_PAYMASTER_WITHDRAWER ?? wallet.address;

  console.log("=== Deploying Envelope on ZkSync ===");
  console.log("Network:        ", hre.network.name);
  console.log("Deployer:       ", wallet.address);
  console.log("MFA Authorizer: ", mfaAuthorizer);
  console.log("Owner:          ", envelopeOwner);
  console.log("Fee Token:      ", feeToken);
  console.log("Deploy Paymaster:", deployPaymaster);
  console.log("");

  // 1. Vault — required.
  const vault = await deployContract(deployer, "EnvelopeLinks", [
    mfaAuthorizer,
    envelopeOwner,
    feeToken,
  ]);
  const vaultAddr = await vault.getAddress();

  // 2. Paymaster — optional. Must be funded with ETH after deployment.
  let paymasterAddr: string | undefined;
  if (deployPaymaster) {
    const envelopePaymaster = await deployContract(
      deployer,
      "EnvelopePaymaster",
      [paymasterAdmin, paymasterWithdrawer, vaultAddr],
    );
    paymasterAddr = await envelopePaymaster.getAddress();
  }

  console.log("");
  console.log("=== Deployment Complete ===");
  console.log("EnvelopeLinks:        ", vaultAddr);
  if (paymasterAddr) console.log("EnvelopePaymaster: ", paymasterAddr);
  console.log("");

  // Verification
  console.log("=== Verifying Contracts ===");
  try {
    console.log("Verifying EnvelopeLinks...");
    await hre.run("verify:verify", {
      address: vaultAddr,
      contract: "src/envelope/EnvelopeLinks.sol:EnvelopeLinks",
      constructorArguments: [mfaAuthorizer, envelopeOwner, feeToken],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  if (paymasterAddr) {
    try {
      console.log("Verifying EnvelopePaymaster...");
      await hre.run("verify:verify", {
        address: paymasterAddr,
        contract: "src/paymasters/EnvelopePaymaster.sol:EnvelopePaymaster",
        constructorArguments: [paymasterAdmin, paymasterWithdrawer, vaultAddr],
      });
    } catch (e: any) {
      console.log("Verification failed or already verified:", e.message);
    }
  }

  console.log("");
  console.log(`=== Add these to ${envFile}: ===`);
  console.log(`ENVELOPE_VAULT=${vaultAddr}`);
  if (paymasterAddr) console.log(`ENVELOPE_PAYMASTER=${paymasterAddr}`);

  if (mfaAuthorizer === ZERO) {
    console.log("");
    console.log(
      "NOTE: ENVELOPE_MFA_AUTHORIZER is 0x0 — claimWithMFA will always revert. Set it before allowing MFA-flagged links in production.",
    );
  }
};
