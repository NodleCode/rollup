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
 *   - PEANUT_ECO_TOKEN:      Address of a rebasing ECO-like ERC20 to gate from
 *                            standard contractType==1 deposits. Defaults to 0x0
 *                            (no gating). Leave unset on Nodle.
 *   - PEANUT_MFA_AUTHORIZER: Address authorized to sign MFA withdraw approvals.
 *                            Defaults to 0x0 (MFA disabled — withdrawMFADeposit reverts).
 *                            Set to your backend signer for production MFA.
 *   - PEANUT_DEPLOY_BATCHER: "true"|"false". Default "true". Deploys PeanutBatcherV4.
 *   - PEANUT_DEPLOY_ROUTER:  "true"|"false". Default "false". Deploys PeanutV4Router
 *                            for cross-chain bridging via Squid.
 *   - PEANUT_SQUID_ADDRESS:  Squid router address. REQUIRED if PEANUT_DEPLOY_ROUTER=true.
 *   - PEANUT_ROUTER_OWNER:   Address to receive Ownable2Step ownership of the router.
 *                            If set and != deployer, the script initiates transferOwnership;
 *                            the new owner must call acceptOwnership() in a follow-up tx.
 *
 * Usage:
 *   yarn hardhat deploy-zksync \
 *     --script DeployPeanut.ts \
 *     --network zkSyncSepoliaTestnet
 */
module.exports = async function (hre: HardhatRuntimeEnvironment) {
  const ZERO = "0x0000000000000000000000000000000000000000";

  const ecoToken = process.env.PEANUT_ECO_TOKEN ?? ZERO;
  const mfaAuthorizer = process.env.PEANUT_MFA_AUTHORIZER ?? ZERO;
  const deployBatcher = (process.env.PEANUT_DEPLOY_BATCHER ?? "true").toLowerCase() === "true";
  const deployRouter = (process.env.PEANUT_DEPLOY_ROUTER ?? "false").toLowerCase() === "true";
  const squidAddress = process.env.PEANUT_SQUID_ADDRESS ?? ZERO;
  const routerOwnerOverride = process.env.PEANUT_ROUTER_OWNER ?? "";

  const rpcUrl = hre.network.config.url!;
  const provider = new Provider(rpcUrl);
  const wallet = new Wallet(process.env.DEPLOYER_PRIVATE_KEY!, provider);
  const deployer = new Deployer(hre, wallet);

  if (deployRouter && squidAddress === ZERO) {
    throw new Error(
      "PEANUT_SQUID_ADDRESS is required when PEANUT_DEPLOY_ROUTER=true",
    );
  }

  console.log("=== Deploying Peanut Protocol on ZkSync ===");
  console.log("Network:        ", hre.network.name);
  console.log("Deployer:       ", wallet.address);
  console.log("ECO Token:      ", ecoToken);
  console.log("MFA Authorizer: ", mfaAuthorizer);
  console.log("Deploy Batcher: ", deployBatcher);
  console.log("Deploy Router:  ", deployRouter);
  if (deployRouter) {
    console.log("Squid Address:  ", squidAddress);
    console.log("Router Owner:   ", routerOwnerOverride || `(deployer: ${wallet.address})`);
  }
  console.log("");

  // 1. Vault — required.
  const peanut = await deployContract(deployer, "PeanutV4", [ecoToken, mfaAuthorizer]);
  const peanutAddr = await peanut.getAddress();

  // 2. Batcher — optional.
  let batcherAddr: string | undefined;
  if (deployBatcher) {
    const batcher = await deployContract(deployer, "PeanutBatcherV4", []);
    batcherAddr = await batcher.getAddress();
  }

  // 3. Router — optional, cross-chain via Squid.
  let routerAddr: string | undefined;
  let pendingRouterOwner: string | undefined;
  if (deployRouter) {
    const router = await deployContract(deployer, "PeanutV4Router", [squidAddress]);
    routerAddr = await router.getAddress();

    if (routerOwnerOverride && routerOwnerOverride.toLowerCase() !== wallet.address.toLowerCase()) {
      console.log(`Initiating Ownable2Step handoff -> ${routerOwnerOverride} ...`);
      const tx = await router.transferOwnership(routerOwnerOverride);
      await tx.wait();
      pendingRouterOwner = routerOwnerOverride;
      console.log(`  transferOwnership tx: ${tx.hash}`);
      console.log(`  new owner must call acceptOwnership() to finalize`);
    }
  }

  console.log("");
  console.log("=== Deployment Complete ===");
  console.log("PeanutV4:        ", peanutAddr);
  if (batcherAddr) console.log("PeanutBatcherV4: ", batcherAddr);
  if (routerAddr) console.log("PeanutV4Router:  ", routerAddr);
  console.log("");

  // Verification
  console.log("=== Verifying Contracts ===");
  try {
    console.log("Verifying PeanutV4...");
    await hre.run("verify:verify", {
      address: peanutAddr,
      contract: "src/peanut/V4/PeanutV4.4.sol:PeanutV4",
      constructorArguments: [ecoToken, mfaAuthorizer],
    });
  } catch (e: any) {
    console.log("Verification failed or already verified:", e.message);
  }

  if (batcherAddr) {
    try {
      console.log("Verifying PeanutBatcherV4...");
      await hre.run("verify:verify", {
        address: batcherAddr,
        contract: "src/peanut/V4/PeanutBatcherV4.4.sol:PeanutBatcherV4",
        constructorArguments: [],
      });
    } catch (e: any) {
      console.log("Verification failed or already verified:", e.message);
    }
  }

  if (routerAddr) {
    try {
      console.log("Verifying PeanutV4Router...");
      await hre.run("verify:verify", {
        address: routerAddr,
        contract: "src/peanut/V4/PeanutRouter.sol:PeanutV4Router",
        constructorArguments: [squidAddress],
      });
    } catch (e: any) {
      console.log("Verification failed or already verified:", e.message);
    }
  }

  console.log("");
  console.log("=== Add these to .env-test: ===");
  console.log(`PEANUT_V4=${peanutAddr}`);
  if (batcherAddr) console.log(`PEANUT_BATCHER=${batcherAddr}`);
  if (routerAddr) console.log(`PEANUT_ROUTER=${routerAddr}`);

  if (pendingRouterOwner) {
    console.log("");
    console.log(
      `ACTION REQUIRED: have ${pendingRouterOwner} call PeanutV4Router(${routerAddr}).acceptOwnership() to finalize ownership transfer.`,
    );
  }

  if (mfaAuthorizer === ZERO) {
    console.log("");
    console.log("NOTE: PEANUT_MFA_AUTHORIZER is 0x0 — withdrawMFADeposit will always revert. Set it before allowing MFA-flagged deposits in production.");
  }
};
