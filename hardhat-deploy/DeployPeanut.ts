import { Provider, Wallet } from "zksync-ethers";
import { Deployer } from "@matterlabs/hardhat-zksync";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import * as dotenv from "dotenv";
import { deployContract } from "./utils";

dotenv.config({ path: ".env-test" });

/**
 * Deploys the Peanut Protocol suite on ZkSync Era.
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment.
 *
 * Optional environment variables:
 *   - ENVELOPE_ECO_TOKEN:      Address of a rebasing ECO-like ERC20 to gate from
 *                            standard contractType==1 deposits. Defaults to 0x0
 *                            (no gating). Leave unset on Nodle.
 *   - ENVELOPE_MFA_AUTHORIZER: Address authorized to sign MFA withdraw approvals.
 *                            Defaults to 0x0 (MFA disabled — withdrawMFADeposit reverts).
 *                            Set to your backend signer for production MFA.
 *   - ENVELOPE_DEPLOY_BATCHER: "true"|"false". Default "true". Deploys EnvelopeBatcher.
 *
 * Usage:
 *   yarn hardhat deploy-zksync \
 *     --script DeployPeanut.ts \
 *     --network zkSyncSepoliaTestnet
 */
module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const ZERO = "0x0000000000000000000000000000000000000000";

  const ecoToken = process.env.ENVELOPE_ECO_TOKEN ?? ZERO;
  const mfaAuthorizer = process.env.ENVELOPE_MFA_AUTHORIZER ?? ZERO;
  const deployBatcher = (process.env.ENVELOPE_DEPLOY_BATCHER ?? "true").toLowerCase() === "true";

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  console.log("=== Deploying Peanut Protocol on ZkSync ===");
  console.log("Network:        ", hre.network.name);
  console.log("Deployer:       ", wallet.address);
  console.log("ECO Token:      ", ecoToken);
  console.log("MFA Authorizer: ", mfaAuthorizer);
  console.log("Deploy Batcher: ", deployBatcher);
  console.log("");

  // 1. Vault — required.
  const peanut = await deployContract(deployer, "EnvelopeVault", [ecoToken, mfaAuthorizer]);
  const peanutAddr = await peanut.getAddress();

  // 2. Batcher — optional.
  let batcherAddr: string | undefined;
  if (deployBatcher) {
    const batcher = await deployContract(deployer, "EnvelopeBatcher", []);
    batcherAddr = await batcher.getAddress();
  }

  console.log("");
  console.log("=== Deployment Complete ===");
  console.log("EnvelopeVault:        ", peanutAddr);
  if (batcherAddr) console.log("EnvelopeBatcher: ", batcherAddr);
  console.log("");

  // Verification
  console.log("=== Verifying Contracts ===");
  try {
    console.log("Verifying EnvelopeVault...");
    await hre.run("verify:verify", {
      address: peanutAddr,
      contract: "src/envelope/V4/PeanutV4.4.sol:EnvelopeVault",
      constructorArguments: [ecoToken, mfaAuthorizer],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  if (batcherAddr) {
    try {
      console.log("Verifying EnvelopeBatcher...");
      await hre.run("verify:verify", {
        address: batcherAddr,
        contract: "src/envelope/V4/PeanutBatcherV4.4.sol:EnvelopeBatcher",
        constructorArguments: [],
      });
    } catch (e: any) {
      console.log("Verification failed or already verified:", e.message);
    }
  }

  console.log("");
  console.log("=== Add these to .env-test: ===");
  console.log(`ENVELOPE_VAULT=${peanutAddr}`);
  if (batcherAddr) console.log(`ENVELOPE_BATCHER=${batcherAddr}`);

  if (mfaAuthorizer === ZERO) {
    console.log("");
    console.log("NOTE: ENVELOPE_MFA_AUTHORIZER is 0x0 — withdrawMFADeposit will always revert. Set it before allowing MFA-flagged deposits in production.");
  }
};
