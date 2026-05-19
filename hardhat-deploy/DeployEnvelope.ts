import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";
import { deployContract } from "./utils";

dotenv.config({ path: ".env-test" });

/**
 * Deploys the Envelope (vendored Peanut V4.4) suite on ZkSync Era.
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment.
 *
 * Optional environment variables:
 *   - ENVELOPE_MFA_AUTHORIZER: Address authorized to sign MFA withdraw approvals.
 *                            Defaults to 0x0 (MFA disabled — withdrawMFADeposit reverts).
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

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  const mfaAuthorizer = process.env.ENVELOPE_MFA_AUTHORIZER ?? ZERO;
  const envelopeOwner = process.env.ENVELOPE_OWNER ?? wallet.address;
  const feeToken = process.env.ENVELOPE_FEE_TOKEN ?? ZERO;
  const deployPaymaster = (process.env.ENVELOPE_DEPLOY_PAYMASTER ?? "false").toLowerCase() === "true";
  const paymasterAdmin = process.env.ENVELOPE_PAYMASTER_ADMIN ?? wallet.address;
  const paymasterWithdrawer = process.env.ENVELOPE_PAYMASTER_WITHDRAWER ?? wallet.address;

  console.log("=== Deploying Envelope on ZkSync ===");
  console.log("Network:        ", hre.network.name);
  console.log("Deployer:       ", wallet.address);
  console.log("MFA Authorizer: ", mfaAuthorizer);
  console.log("Owner:          ", envelopeOwner);
  console.log("Fee Token:      ", feeToken);
  console.log("Deploy Paymaster:", deployPaymaster);
  console.log("");

  // 1. Vault — required.
  const vault = await deployContract(deployer, "EnvelopeVault", [mfaAuthorizer, envelopeOwner, feeToken]);
  const vaultAddr = await vault.getAddress();

  // 2. Paymaster — optional. Must be funded with ETH after deployment.
  let paymasterAddr: string | undefined;
  if (deployPaymaster) {
    const envelopePaymaster = await deployContract(deployer, "EnvelopePaymaster", [
      paymasterAdmin,
      paymasterWithdrawer,
      vaultAddr,
    ]);
    paymasterAddr = await envelopePaymaster.getAddress();
  }

  console.log("");
  console.log("=== Deployment Complete ===");
  console.log("EnvelopeVault:        ", vaultAddr);
  if (paymasterAddr) console.log("EnvelopePaymaster: ", paymasterAddr);
  console.log("");

  // Verification
  console.log("=== Verifying Contracts ===");
  try {
    console.log("Verifying EnvelopeVault...");
    await hre.run("verify:verify", {
      address: vaultAddr,
      contract: "src/envelope/V4/EnvelopeVault.sol:EnvelopeVault",
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
  console.log("=== Add these to .env-test: ===");
  console.log(`ENVELOPE_VAULT=${vaultAddr}`);
  if (paymasterAddr) console.log(`ENVELOPE_PAYMASTER=${paymasterAddr}`);

  if (mfaAuthorizer === ZERO) {
    console.log("");
    console.log("NOTE: ENVELOPE_MFA_AUTHORIZER is 0x0 — withdrawMFADeposit will always revert. Set it before allowing MFA-flagged deposits in production.");
  }
};
