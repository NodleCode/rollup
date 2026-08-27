// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {FundraiserFactory} from "../src/fundraising/FundraiserFactory.sol";

/**
 * @title DeployFundraiserFactory
 * @notice Deployment script for the group fundraising system on ZkSync Era.
 * @dev See `src/fundraising/doc/spec/group-fundraising-design.md`.
 *
 *      One deployment, and only one. There is no implementation contract and no proxy:
 *      each fundraise is a full `Fundraiser` deployed by the factory with `new`, whose
 *      bytecode zksolc registers as a factory dependency at compile time. That is what
 *      makes the deploy resolvable on EraVM, where `create` is lowered to a
 *      `ContractDeployer` call keyed on a bytecode hash the operator must already know.
 *
 *      Fees ship switched off. The capability exists — the rate is snapshotted into each
 *      fundraise at creation and capped by a constant — but charging a group to pool its
 *      own money is a product decision, so `N_FUNDRAISING_FEE_BPS` defaults to zero.
 *
 * Usage:
 *   forge script script/DeployFundraiserFactory.s.sol \
 *       --rpc-url $L2_RPC --broadcast --zksync
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY:         Private key with ETH for gas.
 *   - N_FUNDRAISING_ADMIN:          Multisig that will hold DEFAULT_ADMIN_ROLE.
 *   - N_FUNDRAISING_TOKENS:         Comma-separated ERC-20 addresses to allow at launch,
 *                                   e.g. the USDC and NODL addresses for the network.
 *   - N_FUNDRAISING_FEE_BPS:        Optional, defaults to 0. Capped by MAX_FEE_BPS.
 *   - N_FUNDRAISING_FEE_RECIPIENT:  Optional, required only when the rate is non-zero.
 */
contract DeployFundraiserFactory is Script {
    FundraiserFactory public factory;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("N_FUNDRAISING_ADMIN");

        address[] memory noTokens = new address[](0);
        address[] memory tokens = vm.envOr("N_FUNDRAISING_TOKENS", ",", noTokens);

        uint256 feeBpsRaw = vm.envOr("N_FUNDRAISING_FEE_BPS", uint256(0));
        address feeRecipient = vm.envOr("N_FUNDRAISING_FEE_RECIPIENT", address(0));

        require(admin != address(0), "N_FUNDRAISING_ADMIN is zero");
        require(feeBpsRaw <= type(uint16).max, "N_FUNDRAISING_FEE_BPS out of range");
        // The constructor enforces this too; failing here saves a broadcast round-trip.
        require(feeBpsRaw == 0 || feeRecipient != address(0), "fee rate set with no recipient");
        // An empty allow-list would deploy a factory that cannot create anything.
        require(tokens.length != 0, "N_FUNDRAISING_TOKENS is empty");

        uint16 feeBps = uint16(feeBpsRaw);

        console.log("=== Deploying Group Fundraising on ZkSync ===");
        console.log("Admin:", admin);
        console.log("Fee bps:", feeBps);
        console.log("Fee recipient:", feeRecipient);
        console.log("Allowed tokens:", tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(tokens[i] != address(0), "N_FUNDRAISING_TOKENS contains the zero address");
            console.log("   -", tokens[i]);
        }
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        console.log("1. Deploying FundraiserFactory...");
        factory = new FundraiserFactory(admin, feeBps, feeRecipient, tokens);
        console.log("   FundraiserFactory:", address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("FundraiserFactory: ", address(factory));
        console.log("Admin (DEFAULT_ADMIN_ROLE):", admin);
        console.log("MAX_FEE_BPS:", factory.MAX_FEE_BPS());
        console.log("MAX_DURATION (seconds):", factory.MAX_DURATION());
        console.log("");
        console.log("No implementation and no proxy were deployed; each fundraise is a");
        console.log("full contract created by the factory. Verify the factory only.");
    }
}
