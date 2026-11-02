// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {ArcadeEscrow} from "../src/arcade/ArcadeEscrow.sol";

/**
 * @title DeployArcadeEscrow
 * @notice Deployment script for the Arcade NODL escrow on ZkSync Era.
 * @dev Design: agent-stack `docs/arcade-artifacts-backend-design.md`, section 9.3.
 *
 *      The contract holds user funds and is not upgradeable: there is no proxy. To sponsor
 *      gas for `deposit`, whitelist the deployed address on the existing `WhitelistPaymaster`
 *      (`addWhitelistedContracts`); that is a separate admin transaction.
 *
 * Usage:
 *   forge script script/DeployArcadeEscrow.s.sol \
 *       --rpc-url $L2_RPC --broadcast --zksync
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY:            Private key with ETH for gas.
 *   - N_TOKEN_ADDR:                    NODL token address.
 *   - N_ARCADE_ADMIN:                  Multisig that will hold DEFAULT_ADMIN_ROLE.
 *   - N_ARCADE_ORACLE:                 arcade-forge settlement key, granted ORACLE_ROLE.
 *   - N_ARCADE_QUOTA:                  Total NODL (wei) that may be charged per period.
 *   - N_ARCADE_PERIOD:                 Optional quota period in seconds, defaults to 1 day.
 *   - N_ARCADE_MIN_DEPOSIT:            Smallest deposit (wei) into an empty balance.
 *   - N_ARCADE_MAX_CHARGE:             Largest single charge (wei).
 *   - N_ARCADE_WITHDRAW_DELAY:         Optional, seconds, defaults to 1 hour.
 */
contract DeployArcadeEscrow is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address nodl = vm.envAddress("N_TOKEN_ADDR");
        address admin = vm.envAddress("N_ARCADE_ADMIN");
        address oracle = vm.envAddress("N_ARCADE_ORACLE");
        uint256 quota = vm.envUint("N_ARCADE_QUOTA");
        uint256 period = vm.envOr("N_ARCADE_PERIOD", uint256(1 days));
        uint256 minDeposit = vm.envUint("N_ARCADE_MIN_DEPOSIT");
        uint256 maxCharge = vm.envUint("N_ARCADE_MAX_CHARGE");
        uint256 withdrawDelayRaw = vm.envOr("N_ARCADE_WITHDRAW_DELAY", uint256(1 hours));

        // The constructor enforces the delay cap too; failing here saves a broadcast round-trip.
        require(withdrawDelayRaw <= type(uint64).max, "N_ARCADE_WITHDRAW_DELAY out of range");
        require(maxCharge != 0, "N_ARCADE_MAX_CHARGE is zero");
        require(quota >= maxCharge, "N_ARCADE_QUOTA is below one max charge");
        uint64 withdrawDelay = uint64(withdrawDelayRaw);

        console.log("=== Deploying ArcadeEscrow on ZkSync ===");
        console.log("NODL:", nodl);
        console.log("Admin:", admin);
        console.log("Oracle:", oracle);
        console.log("Quota / period:", quota, period);
        console.log("Min deposit:", minDeposit);
        console.log("Max charge:", maxCharge);
        console.log("Withdraw delay:", withdrawDelay);

        vm.startBroadcast(deployerPrivateKey);
        ArcadeEscrow escrow = new ArcadeEscrow(nodl, oracle, admin, quota, period, minDeposit, maxCharge, withdrawDelay);
        vm.stopBroadcast();

        console.log("");
        console.log("ArcadeEscrow:", address(escrow));
    }
}
