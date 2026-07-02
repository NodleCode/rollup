// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {EnvelopeLinks} from "../src/envelope/EnvelopeLinks.sol";
import {EnvelopePaymaster} from "../src/paymasters/EnvelopePaymaster.sol";

/**
 * @title DeployEnvelopeZkSync
 * @notice Deploys EnvelopeLinks and, optionally, EnvelopePaymaster on ZkSync Era.
 *
 * @dev Do NOT use `forge script --verify` on ZkSync for these contracts.
 *      Deploy with forge, then run `ops/verify_zksync_contracts.py` against the
 *      generated broadcast JSON. See the Usage section below.
 *
 * Usage:
 *   forge script script/DeployEnvelopeZkSync.s.sol --rpc-url $L2_RPC --broadcast --zksync \
 *     --skip src/swarms/SwarmRegistryL1Upgradeable.sol \
 *     --skip test/SwarmRegistryL1.t.sol \
 *     --skip test/upgrade-demo/TestUpgradeOnAnvil.s.sol \
 *     --skip script/DeploySwarmUpgradeable.s.sol \
 *     --skip script/UpgradeSwarm.s.sol
 *
 *   # After deployment, verify via the custom helper instead of forge --verify:
 *   python3 ops/verify_zksync_contracts.py \
 *     --broadcast broadcast/DeployEnvelopeZkSync.s.sol/324/run-latest.json \
 *     --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification
 *
 * Required environment variables:
 *   - DEPLOYER_PRIVATE_KEY
 *
 * Optional environment variables:
 *   - ENVELOPE_MFA_AUTHORIZER
 *   - ENVELOPE_OWNER
 *   - ENVELOPE_FEE_TOKEN
 *   - ENVELOPE_DEPLOY_PAYMASTER        (true|false, default false)
 *   - ENVELOPE_PAYMASTER_ADMIN
 *   - ENVELOPE_PAYMASTER_WITHDRAWER
 */
contract DeployEnvelopeZkSync is Script {
    address public vaultAddr;
    address public paymasterAddr;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address mfaAuthorizer = vm.envOr("ENVELOPE_MFA_AUTHORIZER", address(0));
        address envelopeOwner = vm.envOr("ENVELOPE_OWNER", deployer);
        address feeToken = vm.envOr("ENVELOPE_FEE_TOKEN", address(0));
        bool deployPaymaster = vm.envOr("ENVELOPE_DEPLOY_PAYMASTER", false);
        address paymasterAdmin = vm.envOr("ENVELOPE_PAYMASTER_ADMIN", deployer);
        address paymasterWithdrawer = vm.envOr("ENVELOPE_PAYMASTER_WITHDRAWER", deployer);

        console.log("=== Deploying Envelope ===");
        console.log("Deployer:", deployer);
        console.log("MFA Authorizer:", mfaAuthorizer);
        console.log("Owner:", envelopeOwner);
        console.log("Fee Token:", feeToken);
        console.log("Deploy Paymaster:", deployPaymaster);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        EnvelopeLinks vault = new EnvelopeLinks(mfaAuthorizer, envelopeOwner, feeToken);
        vaultAddr = address(vault);

        if (deployPaymaster) {
            EnvelopePaymaster paymaster = new EnvelopePaymaster(paymasterAdmin, paymasterWithdrawer, vaultAddr);
            paymasterAddr = address(paymaster);
        }

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("EnvelopeLinks:", vaultAddr);
        if (paymasterAddr != address(0)) {
            console.log("EnvelopePaymaster:", paymasterAddr);
        }
        console.log("");
        console.log("=== Env vars ===");
        console.log("ENVELOPE_VAULT=%s", vaultAddr);
        if (paymasterAddr != address(0)) {
            console.log("ENVELOPE_PAYMASTER=%s", paymasterAddr);
        }
        if (mfaAuthorizer == address(0)) {
            console.log("");
            console.log("NOTE: MFA auth is 0x0.");
            console.log("claimWithMFA stays disabled.");
        }
        console.log("");
        console.log("=== Verification Note ===");
        console.log("Use verify_zksync_contracts.py");
        console.log("No forge script --verify");
    }
}