// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DeployPaymentZkSync} from "../script/DeployPaymentZkSync.s.sol";
import {Payment} from "../src/Payment.sol";

contract MockNodl is ERC20 {
    constructor() ERC20("Nodle", "NODL") {}
}

contract MockOther is ERC20 {
    constructor() ERC20("Other", "MTK") {}
}

/// @dev These tests call `validate` and `deployWith` directly and never set env vars:
///      `forge test` runs tests in parallel and `vm.setEnv` would race between them.
contract DeployPaymentZkSyncTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;

    DeployPaymentZkSync internal deployScript;
    MockNodl internal nodl;
    MockOther internal other;
    address internal deployer;
    address internal admin;
    address internal oracle;

    function setUp() public {
        deployScript = new DeployPaymentZkSync();
        nodl = new MockNodl();
        other = new MockOther();
        deployer = vm.addr(DEPLOYER_KEY);
        admin = makeAddr("safe");
        oracle = makeAddr("payer");
    }

    function _baseParams() internal view returns (DeployPaymentZkSync.Params memory) {
        return DeployPaymentZkSync.Params({
            token: address(nodl), admin: admin, oracle: oracle, quota: 200_000 ether, period: 1 days
        });
    }

    function test_deployWith_setsTokenQuotaPeriodAndRoles() public {
        Payment payment = deployScript.deployWith(_baseParams(), DEPLOYER_KEY);

        assertEq(address(payment.token()), address(nodl));
        assertEq(payment.quota(), 200_000 ether);
        assertEq(payment.period(), 1 days);
        assertTrue(payment.hasRole(payment.ORACLE_ROLE(), oracle));
        assertTrue(payment.hasRole(payment.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_deployWith_deployerHoldsNoRole() public {
        Payment payment = deployScript.deployWith(_baseParams(), DEPLOYER_KEY);

        assertFalse(payment.hasRole(payment.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(payment.hasRole(payment.ORACLE_ROLE(), deployer));
    }

    function test_validate_rejectsAdminEqualsOracle() public {
        DeployPaymentZkSync.Params memory p = _baseParams();
        p.admin = p.oracle;

        vm.expectRevert(bytes("N_PAYMENT_ADMIN equals N_PAYMENT_ORACLE"));
        deployScript.validate(p, deployer);
    }

    function test_validate_rejectsDeployerIsOracle() public {
        DeployPaymentZkSync.Params memory p = _baseParams();
        p.oracle = deployer;

        vm.expectRevert(bytes("deploy with a key other than the payer"));
        deployScript.validate(p, deployer);
    }

    function test_validate_rejectsQuotaBelowOneNodl() public {
        DeployPaymentZkSync.Params memory p = _baseParams();
        p.quota = 200_000;

        vm.expectRevert(bytes("N_PAYMENT_QUOTA is below 1 NODL, amounts are in wei"));
        deployScript.validate(p, deployer);
    }

    function test_validate_rejectsPeriodOutOfRange() public {
        DeployPaymentZkSync.Params memory p = _baseParams();

        p.period = 0;
        vm.expectRevert(bytes("N_PAYMENT_PERIOD out of range"));
        deployScript.validate(p, deployer);

        p.period = 31 days;
        vm.expectRevert(bytes("N_PAYMENT_PERIOD out of range"));
        deployScript.validate(p, deployer);

        // The script's bound must track QuotaControl.MAX_PERIOD: the limit itself is accepted, one second over is not.
        Payment deployed = deployScript.deployWith(_baseParams(), DEPLOYER_KEY);
        assertEq(deployScript.MAX_PERIOD(), deployed.MAX_PERIOD());
        p.period = deployed.MAX_PERIOD();
        deployScript.validate(p, deployer);
        p.period = deployed.MAX_PERIOD() + 1;
        vm.expectRevert(bytes("N_PAYMENT_PERIOD out of range"));
        deployScript.validate(p, deployer);
    }

    function test_validate_rejectsNonNodlToken() public {
        DeployPaymentZkSync.Params memory p = _baseParams();
        p.token = address(other);

        vm.expectRevert(bytes("N_TOKEN_ADDR is not NODL"));
        deployScript.validate(p, deployer);
    }

    function test_validate_rejectsZeroAddress() public {
        DeployPaymentZkSync.Params memory p = _baseParams();
        p.admin = address(0);

        vm.expectRevert(bytes("zero address"));
        deployScript.validate(p, deployer);
    }
}
