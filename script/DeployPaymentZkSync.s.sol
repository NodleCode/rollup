// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Payment} from "../src/Payment.sol";

/**
 * @title DeployPaymentZkSync
 * @notice Deployment script for a general-purpose `Payment` instance (the payouts contract) on ZkSync Era.
 * @dev The contract pays NODL out to recipients in batches, capped by a per-period quota. The admin
 *      (a Safe) funds it, tunes the quota and period, and can withdraw. The oracle (the payer key)
 *      calls `pay`. The deployer ends up holding no role: both roles go to the constructor arguments.
 *
 *      Gas sponsorship for the oracle is not part of this deployment. It is a separate Safe batch on
 *      `BondTreasuryPaymaster`.
 *
 * Usage:
 *   forge script script/DeployPaymentZkSync.s.sol \
 *       --rpc-url $L2_RPC --broadcast --zksync
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY:            Private key with ETH for gas. Must not be the payer key.
 *   - N_TOKEN_ADDR:                    NODL token address.
 *   - N_PAYMENT_ADMIN:                 Multisig that will hold DEFAULT_ADMIN_ROLE.
 *   - N_PAYMENT_ORACLE:                Payer key, granted ORACLE_ROLE.
 *   - N_PAYMENT_QUOTA:                 Total NODL (wei) that may be paid per period.
 *   - N_PAYMENT_PERIOD:                Optional quota period in seconds, defaults to 1 day.
 */
contract DeployPaymentZkSync is Script {
    /// @dev Mirrors `QuotaControl.MAX_PERIOD`. Solidity cannot read a contract's constant without an
    ///      instance, so the test suite pins this value to the deployed contract's constant.
    uint256 public constant MAX_PERIOD = 30 days;

    struct Params {
        address token;
        address admin;
        address oracle;
        uint256 quota;
        uint256 period;
    }

    function run() external returns (Payment) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        Params memory p = Params({
            token: vm.envAddress("N_TOKEN_ADDR"),
            admin: vm.envAddress("N_PAYMENT_ADMIN"),
            oracle: vm.envAddress("N_PAYMENT_ORACLE"),
            quota: vm.envUint("N_PAYMENT_QUOTA"),
            period: vm.envOr("N_PAYMENT_PERIOD", uint256(1 days))
        });

        return deployWith(p, deployerPrivateKey);
    }

    function deployWith(Params memory p, uint256 deployerKey) public returns (Payment) {
        address deployer = vm.addr(deployerKey);
        validate(p, deployer);

        console.log("=== Deploying Payment on ZkSync ===");
        console.log("NODL:", p.token);
        console.log("Admin:", p.admin);
        console.log("Oracle:", p.oracle);
        console.log("Quota / period:", p.quota, p.period);

        vm.startBroadcast(deployerKey);
        Payment payment = new Payment(p.oracle, p.token, p.quota, p.period, p.admin);
        vm.stopBroadcast();

        require(payment.hasRole(payment.DEFAULT_ADMIN_ROLE(), p.admin), "admin role not granted");
        require(payment.hasRole(payment.ORACLE_ROLE(), p.oracle), "oracle role not granted");
        require(!payment.hasRole(payment.DEFAULT_ADMIN_ROLE(), deployer), "deployer holds the admin role");
        require(!payment.hasRole(payment.ORACLE_ROLE(), deployer), "deployer holds the oracle role");

        console.log("");
        console.log("Payment:", address(payment));

        return payment;
    }

    /// @notice Rejects inputs that would deploy a misconfigured instance; the token cannot be changed afterwards.
    function validate(Params memory p, address deployer) public view {
        require(p.token != address(0) && p.admin != address(0) && p.oracle != address(0), "zero address");
        require(p.admin != p.oracle, "N_PAYMENT_ADMIN equals N_PAYMENT_ORACLE");
        require(deployer != p.oracle, "deploy with a key other than the payer");
        require(p.quota >= 1 ether, "N_PAYMENT_QUOTA is below 1 NODL, amounts are in wei");
        require(p.period != 0 && p.period <= MAX_PERIOD, "N_PAYMENT_PERIOD out of range");
        require(keccak256(bytes(IERC20Metadata(p.token).symbol())) == keccak256("NODL"), "N_TOKEN_ADDR is not NODL");
    }
}
