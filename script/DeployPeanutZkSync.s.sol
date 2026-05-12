// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {PeanutV4} from "../src/peanut/V4/PeanutV4.4.sol";
import {PeanutBatcherV4} from "../src/peanut/V4/PeanutBatcherV4.4.sol";
import {PeanutV4Router} from "../src/peanut/V4/PeanutRouter.sol";

/**
 * @title  DeployPeanutZkSync
 * @notice Deployment script for the Peanut Protocol contracts on ZkSync Era.
 * @dev    Deploys PeanutV4 (vault), PeanutBatcherV4 (batched-deposit helper), and
 *         optionally PeanutV4Router (cross-chain via Squid).
 *
 * Usage:
 *   forge script script/DeployPeanutZkSync.s.sol \
 *     --rpc-url $L2_RPC \
 *     --broadcast \
 *     --verify \
 *     --zksync
 *
 * Note on the repo's existing zksync compile state:
 *   `src/swarms/SwarmRegistryL1Upgradeable.sol` uses EXTCODECOPY (L1-only) and is not
 *   excluded from the [profile.zksync] in foundry.toml. If `forge script --zksync` fails
 *   with that error, exclude L1 sources for the run, e.g.:
 *     forge script script/DeployPeanutZkSync.s.sol --zksync \
 *       --skip 'src/swarms/SwarmRegistryL1Upgradeable.sol' \
 *       --skip 'test/FleetIdentity.t.sol' \
 *       --skip 'test/upgrade-demo/TestUpgradeOnAnvil.s.sol' \
 *       --rpc-url $L2_RPC --broadcast --verify
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment.
 *
 * Optional environment variables:
 *   - ECO_TOKEN:      Address of a rebasing ECO-like ERC20 to gate from contractType==1
 *                     deposits. Defaults to address(0) (no gating).
 *   - MFA_AUTHORIZER: Address authorized to sign MFA withdraw approvals.
 *                     Defaults to address(0) (MFA disabled — withdrawMFADeposit always reverts).
 *   - DEPLOY_BATCHER: "true" to deploy PeanutBatcherV4. Defaults to "true".
 *   - DEPLOY_ROUTER:  "true" to deploy PeanutV4Router. Defaults to "false".
 *   - SQUID_ADDRESS:  Squid router address. REQUIRED if DEPLOY_ROUTER=true.
 *   - ROUTER_OWNER:   Address to receive Ownable2Step ownership of PeanutV4Router.
 *                     If set and != deployer, the script initiates transferOwnership;
 *                     the new owner must call acceptOwnership() in a separate tx.
 *                     Defaults to keeping ownership with the deployer.
 */
contract DeployPeanutZkSync is Script {
    PeanutV4 public peanut;
    PeanutBatcherV4 public batcher;
    PeanutV4Router public router;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address ecoToken = vm.envOr("ECO_TOKEN", address(0));
        address mfaAuthorizer = vm.envOr("MFA_AUTHORIZER", address(0));
        bool deployBatcher = vm.envOr("DEPLOY_BATCHER", true);
        bool deployRouter = vm.envOr("DEPLOY_ROUTER", false);
        address squidAddress = vm.envOr("SQUID_ADDRESS", address(0));
        address routerOwner = vm.envOr("ROUTER_OWNER", deployer);

        console.log("=== Deploying Peanut Protocol on ZkSync ===");
        console.log("Deployer:        ", deployer);
        console.log("ECO Token:       ", ecoToken);
        console.log("MFA Authorizer:  ", mfaAuthorizer);
        console.log("Deploy Batcher:  ", deployBatcher);
        console.log("Deploy Router:   ", deployRouter);
        if (deployRouter) {
            console.log("Squid Address:   ", squidAddress);
            console.log("Router Owner:    ", routerOwner);
            require(squidAddress != address(0), "SQUID_ADDRESS required when DEPLOY_ROUTER=true");
        }
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Vault
        console.log("1. Deploying PeanutV4 (vault)...");
        peanut = new PeanutV4(ecoToken, mfaAuthorizer);
        console.log("   PeanutV4:        ", address(peanut));
        console.log("");

        // 2. Batcher (optional)
        if (deployBatcher) {
            console.log("2. Deploying PeanutBatcherV4...");
            batcher = new PeanutBatcherV4();
            console.log("   PeanutBatcherV4: ", address(batcher));
            console.log("");
        }

        // 3. Router (optional, cross-chain via Squid)
        if (deployRouter) {
            console.log("3. Deploying PeanutV4Router...");
            router = new PeanutV4Router(squidAddress);
            console.log("   PeanutV4Router:  ", address(router));

            // Ownable2Step: transferOwnership only initiates. The new owner must call
            // acceptOwnership() from their own key in a follow-up tx — we cannot do it here.
            if (routerOwner != deployer) {
                console.log("   transferOwnership ->", routerOwner);
                router.transferOwnership(routerOwner);
                console.log("   pending owner set; new owner must call acceptOwnership()");
            }
            console.log("");
        }

        vm.stopBroadcast();

        // Summary
        console.log("=== Deployment Complete ===");
        console.log("PeanutV4:        ", address(peanut));
        if (deployBatcher) console.log("PeanutBatcherV4: ", address(batcher));
        if (deployRouter) {
            console.log("PeanutV4Router:  ", address(router));
            if (routerOwner != deployer) {
                console.log("");
                console.log("ACTION REQUIRED: have", routerOwner, "call:");
                console.log("  PeanutV4Router(", address(router));
                console.log("  ).acceptOwnership()");
            }
        }
        console.log("");
        console.log("Save these addresses for the SDK / frontend integration.");
        if (mfaAuthorizer == address(0)) {
            console.log("NOTE: MFA_AUTHORIZER is address(0) - withdrawMFADeposit will always revert.");
        }
    }
}
