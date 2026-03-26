// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";
import {BasePaymaster} from "../../src/paymasters/BasePaymaster.sol";
import {FleetTreasuryPaymaster} from "../../src/paymasters/FleetTreasuryPaymaster.sol";
import {QuotaControl} from "../../src/QuotaControl.sol";
import {FleetIdentityUpgradeable} from "../../src/swarms/FleetIdentityUpgradeable.sol";

contract MockERC20SCP is ERC20 {
    constructor() ERC20("Mock Bond Token", "MBOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Exposes internal paymaster validation for unit testing.
contract MockFleetTreasuryPaymaster is FleetTreasuryPaymaster {
    constructor(
        address admin,
        address withdrawer,
        address fleetIdentity_,
        address bondToken_,
        uint256 initialQuota,
        uint256 initialPeriod
    ) FleetTreasuryPaymaster(admin, withdrawer, fleetIdentity_, bondToken_, initialQuota, initialPeriod) {}

    function mock_validateAndPayGeneralFlow(address from, address to, uint256 requiredETH) public view {
        _validateAndPayGeneralFlow(from, to, requiredETH);
    }

    function mock_validateAndPayApprovalBasedFlow(
        address from,
        address to,
        address token,
        uint256 amount,
        bytes memory data,
        uint256 requiredETH
    ) public pure {
        _validateAndPayApprovalBasedFlow(from, to, token, amount, data, requiredETH);
    }
}

contract FleetTreasuryPaymasterTest is Test {
    using AccessControlUtils for Vm;

    FleetIdentityUpgradeable fleet;
    MockFleetTreasuryPaymaster paymaster;
    MockERC20SCP bondToken;

    address internal admin = address(0x1111);
    address internal withdrawer = address(0x2222);
    address internal alice = address(0xA);
    address internal bob = address(0xB);

    bytes16 constant UUID_1 = bytes16(keccak256("fleet-alpha"));
    bytes16 constant UUID_2 = bytes16(keccak256("fleet-bravo"));
    bytes16 constant UUID_3 = bytes16(keccak256("fleet-charlie"));

    uint256 constant BASE_BOND = 100 ether;
    uint256 constant QUOTA = 1000 ether; // allows 10 claims at BASE_BOND each
    uint256 constant PERIOD = 1 days;

    address[] internal whitelistTargets;

    function setUp() public {
        bondToken = new MockERC20SCP();

        // Deploy FleetIdentity via proxy
        FleetIdentityUpgradeable impl = new FleetIdentityUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FleetIdentityUpgradeable.initialize, (admin, address(bondToken), BASE_BOND, 0))
        );
        fleet = FleetIdentityUpgradeable(address(proxy));

        // Deploy merged paymaster/treasury
        paymaster = new MockFleetTreasuryPaymaster(admin, withdrawer, address(fleet), address(bondToken), QUOTA, PERIOD);

        // Fund paymaster with NODL for bonds
        bondToken.mint(address(paymaster), 10_000 ether);

        // Whitelist alice
        whitelistTargets = new address[](1);
        whitelistTargets[0] = alice;
        vm.prank(admin);
        paymaster.addWhitelistedUsers(whitelistTargets);
    }

    // ══════════════════════════════════════════════
    // ACLs & Immutables
    // ══════════════════════════════════════════════

    function test_defaultACLs() public view {
        assertTrue(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(paymaster.hasRole(paymaster.WHITELIST_ADMIN_ROLE(), admin));
        assertTrue(paymaster.hasRole(paymaster.WITHDRAWER_ROLE(), withdrawer));
    }

    function test_immutables() public view {
        assertEq(paymaster.fleetIdentity(), address(fleet));
        assertEq(address(paymaster.bondToken()), address(bondToken));
    }

    // ══════════════════════════════════════════════
    // Whitelist Management
    // ══════════════════════════════════════════════

    function test_whitelistAdminUpdatesWhitelist() public {
        address[] memory targets = new address[](1);
        targets[0] = bob;

        vm.startPrank(admin);

        assertFalse(paymaster.isWhitelistedUser(bob));

        vm.expectEmit();
        emit FleetTreasuryPaymaster.WhitelistedUsersAdded(targets);
        paymaster.addWhitelistedUsers(targets);
        assertTrue(paymaster.isWhitelistedUser(bob));

        vm.expectEmit();
        emit FleetTreasuryPaymaster.WhitelistedUsersRemoved(targets);
        paymaster.removeWhitelistedUsers(targets);
        assertFalse(paymaster.isWhitelistedUser(bob));

        vm.stopPrank();
    }

    function test_nonWhitelistAdminCannotUpdateWhitelist() public {
        vm.startPrank(withdrawer);

        vm.expectRevert_AccessControlUnauthorizedAccount(withdrawer, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.addWhitelistedUsers(whitelistTargets);

        vm.expectRevert_AccessControlUnauthorizedAccount(withdrawer, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.removeWhitelistedUsers(whitelistTargets);

        vm.stopPrank();
    }

    // ══════════════════════════════════════════════
    // Paymaster Validation
    // ══════════════════════════════════════════════

    function test_generalFlowValidation_success() public {
        vm.deal(address(paymaster), 10 ether);
        paymaster.mock_validateAndPayGeneralFlow(alice, address(fleet), 1 ether);
    }

    function test_generalFlowValidation_adminToSelf_success() public {
        vm.deal(address(paymaster), 10 ether);
        paymaster.mock_validateAndPayGeneralFlow(admin, address(paymaster), 1 ether);
    }

    function test_RevertIf_nonAdminToSelf_destinationNotAllowed() public {
        vm.deal(address(paymaster), 10 ether);
        vm.expectRevert(FleetTreasuryPaymaster.DestinationNotAllowed.selector);
        paymaster.mock_validateAndPayGeneralFlow(alice, address(paymaster), 1 ether);
    }

    function test_RevertIf_adminToSelf_paymasterBalanceTooLow() public {
        vm.expectRevert(FleetTreasuryPaymaster.PaymasterBalanceTooLow.selector);
        paymaster.mock_validateAndPayGeneralFlow(admin, address(paymaster), 1 ether);
    }

    function test_doesNotSupportApprovalBasedFlow() public {
        vm.expectRevert(BasePaymaster.PaymasterFlowNotSupported.selector);
        paymaster.mock_validateAndPayApprovalBasedFlow(alice, address(fleet), address(0), 1, "0x", 0);
    }

    function test_RevertIf_destinationNotAllowed() public {
        vm.expectRevert(FleetTreasuryPaymaster.DestinationNotAllowed.selector);
        paymaster.mock_validateAndPayGeneralFlow(alice, address(0xDEAD), 0);
    }

    function test_RevertIf_userIsNotWhitelisted_paymaster() public {
        vm.expectRevert(FleetTreasuryPaymaster.UserIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(bob, address(fleet), 0);
    }

    function test_RevertIf_paymasterBalanceTooLow() public {
        vm.expectRevert(FleetTreasuryPaymaster.PaymasterBalanceTooLow.selector);
        paymaster.mock_validateAndPayGeneralFlow(alice, address(fleet), 1 ether);
    }

    // ══════════════════════════════════════════════
    // Treasury: consumeSponsoredBond
    // ══════════════════════════════════════════════

    function test_consumeSponsoredBond_success() public {
        // Only FleetIdentity can call consumeSponsoredBond
        vm.prank(address(fleet));
        paymaster.consumeSponsoredBond(alice, BASE_BOND);
        assertEq(paymaster.claimed(), BASE_BOND);
    }

    function test_RevertIf_consumeSponsoredBond_notFleetIdentity() public {
        vm.prank(alice);
        vm.expectRevert(FleetTreasuryPaymaster.NotFleetIdentity.selector);
        paymaster.consumeSponsoredBond(alice, BASE_BOND);
    }

    function test_RevertIf_consumeSponsoredBond_notWhitelisted() public {
        vm.prank(address(fleet));
        vm.expectRevert(FleetTreasuryPaymaster.UserIsNotWhitelisted.selector);
        paymaster.consumeSponsoredBond(bob, BASE_BOND);
    }

    function test_RevertIf_consumeSponsoredBond_insufficientBalance() public {
        // Withdraw all NODL from paymaster
        vm.startPrank(withdrawer);
        paymaster.withdrawTokens(address(bondToken), withdrawer, bondToken.balanceOf(address(paymaster)));
        vm.stopPrank();

        vm.prank(address(fleet));
        vm.expectRevert(FleetTreasuryPaymaster.InsufficientBondBalance.selector);
        paymaster.consumeSponsoredBond(alice, BASE_BOND);
    }

    // ══════════════════════════════════════════════
    // End-to-end: claimUuidSponsored through paymaster
    // ══════════════════════════════════════════════

    function test_sponsoredClaim_e2e() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuidSponsored(UUID_1, address(0), address(paymaster));

        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.ownerOf(tokenId), alice);
        assertEq(tokenId, uint256(uint128(UUID_1)));
    }

    function test_sponsoredClaim_bondFromPaymaster() public {
        uint256 paymasterBefore = bondToken.balanceOf(address(paymaster));

        vm.prank(alice);
        fleet.claimUuidSponsored(UUID_1, address(0), address(paymaster));

        assertEq(bondToken.balanceOf(address(paymaster)), paymasterBefore - BASE_BOND);
    }

    function test_sponsoredClaim_withOperator() public {
        vm.prank(alice);
        fleet.claimUuidSponsored(UUID_1, bob, address(paymaster));

        assertEq(fleet.operatorOf(UUID_1), bob);
        assertEq(fleet.uuidOwner(UUID_1), alice);
    }

    function test_sponsoredClaim_multipleClaims() public {
        address[] memory bobList = new address[](1);
        bobList[0] = bob;
        vm.prank(admin);
        paymaster.addWhitelistedUsers(bobList);

        vm.prank(alice);
        uint256 tokenId1 = fleet.claimUuidSponsored(UUID_1, address(0), address(paymaster));

        vm.prank(bob);
        uint256 tokenId2 = fleet.claimUuidSponsored(UUID_2, address(0), address(paymaster));

        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.uuidOwner(UUID_2), bob);
        assertEq(fleet.ownerOf(tokenId1), alice);
        assertEq(fleet.ownerOf(tokenId2), bob);
    }

    function test_RevertIf_sponsoredClaim_uuidAlreadyClaimed() public {
        vm.prank(alice);
        fleet.claimUuidSponsored(UUID_1, address(0), address(paymaster));

        vm.prank(alice);
        vm.expectRevert(FleetIdentityUpgradeable.UuidAlreadyOwned.selector);
        fleet.claimUuidSponsored(UUID_1, address(0), address(paymaster));
    }

    function test_burnAfterSponsoredClaim_refundsToOwner() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuidSponsored(UUID_1, address(0), address(paymaster));

        uint256 aliceBefore = bondToken.balanceOf(alice);

        vm.prank(alice);
        fleet.burn(tokenId);

        // Refund goes to alice (uuidOwner = msg.sender)
        assertEq(bondToken.balanceOf(alice), aliceBefore + BASE_BOND);
    }

    // ══════════════════════════════════════════════
    // QuotaControl integration
    // ══════════════════════════════════════════════

    function test_quotaParamsSetInConstructor() public view {
        assertEq(paymaster.quota(), QUOTA);
        assertEq(paymaster.period(), PERIOD);
    }

    function test_RevertIf_quotaExceeded() public {
        bondToken.mint(address(paymaster), 100_000 ether);

        // Quota is 1000 ether, each claim costs BASE_BOND (100 ether), so 10 claims exhaust it
        for (uint256 i = 0; i < 10; i++) {
            bytes16 uuid = bytes16(keccak256(abi.encodePacked("uuid-", i)));
            vm.prank(alice);
            fleet.claimUuidSponsored(uuid, address(0), address(paymaster));
        }

        // 11th claim should exceed quota
        vm.prank(alice);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        fleet.claimUuidSponsored(UUID_3, address(0), address(paymaster));
    }

    function test_quotaTracksBaseBondNotClaimCount() public {
        // Deploy paymaster with quota smaller than a single BASE_BOND
        MockFleetTreasuryPaymaster tightPaymaster = new MockFleetTreasuryPaymaster(
            admin, withdrawer, address(fleet), address(bondToken), BASE_BOND / 2, PERIOD
        );

        // Whitelist alice on the tight paymaster
        address[] memory targets = new address[](1);
        targets[0] = alice;
        vm.prank(admin);
        tightPaymaster.addWhitelistedUsers(targets);

        bondToken.mint(address(tightPaymaster), 10_000 ether);

        // BASE_BOND (100 ether) > quota (50 ether), so first claim must revert
        vm.prank(alice);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        fleet.claimUuidSponsored(UUID_1, address(0), address(tightPaymaster));
    }

    function test_quotaResetsAfterPeriod() public {
        bondToken.mint(address(paymaster), 100_000 ether);

        // Exhaust quota (10 claims × 100 ether = 1000 ether)
        for (uint256 i = 0; i < 10; i++) {
            bytes16 uuid = bytes16(keccak256(abi.encodePacked("uuid-", i)));
            vm.prank(alice);
            fleet.claimUuidSponsored(uuid, address(0), address(paymaster));
        }

        // Verify quota is exhausted
        vm.prank(alice);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        fleet.claimUuidSponsored(UUID_3, address(0), address(paymaster));

        // Advance past period
        vm.warp(block.timestamp + PERIOD + 1);

        // Should succeed again after reset
        vm.prank(alice);
        fleet.claimUuidSponsored(UUID_3, address(0), address(paymaster));
        assertEq(fleet.uuidOwner(UUID_3), alice);
    }

    function test_claimedCounterIncrementsCorrectly() public {
        assertEq(paymaster.claimed(), 0);

        vm.prank(alice);
        fleet.claimUuidSponsored(UUID_1, address(0), address(paymaster));
        assertEq(paymaster.claimed(), BASE_BOND);

        address[] memory bobList = new address[](1);
        bobList[0] = bob;
        vm.prank(admin);
        paymaster.addWhitelistedUsers(bobList);

        vm.prank(bob);
        fleet.claimUuidSponsored(UUID_2, address(0), address(paymaster));
        assertEq(paymaster.claimed(), BASE_BOND * 2);
    }

    function test_adminCanUpdateQuota() public {
        vm.prank(admin);
        paymaster.setQuota(500 ether);
        assertEq(paymaster.quota(), 500 ether);
    }

    function test_adminCanUpdatePeriod() public {
        vm.prank(admin);
        paymaster.setPeriod(7 days);
        assertEq(paymaster.period(), 7 days);
    }

    function test_RevertIf_nonAdminUpdatesQuota() public {
        vm.prank(alice);
        vm.expectRevert();
        paymaster.setQuota(500 ether);
    }

    function test_RevertIf_nonAdminUpdatesPeriod() public {
        vm.prank(alice);
        vm.expectRevert();
        paymaster.setPeriod(7 days);
    }

    function test_RevertIf_constructorZeroPeriod() public {
        vm.expectRevert(QuotaControl.ZeroPeriod.selector);
        new MockFleetTreasuryPaymaster(admin, withdrawer, address(fleet), address(bondToken), QUOTA, 0);
    }

    function test_RevertIf_constructorTooLongPeriod() public {
        vm.expectRevert(QuotaControl.TooLongPeriod.selector);
        new MockFleetTreasuryPaymaster(admin, withdrawer, address(fleet), address(bondToken), QUOTA, 31 days);
    }

    // ══════════════════════════════════════════════
    // ERC-20 Withdrawal
    // ══════════════════════════════════════════════

    function test_withdrawTokens() public {
        uint256 amount = 500 ether;

        vm.prank(withdrawer);
        paymaster.withdrawTokens(address(bondToken), withdrawer, amount);

        assertEq(bondToken.balanceOf(withdrawer), amount);
    }

    function test_RevertIf_withdrawTokens_notWithdrawer() public {
        vm.prank(alice);
        vm.expectRevert();
        paymaster.withdrawTokens(address(bondToken), alice, 1 ether);
    }

    function test_withdrawTokensEmitsEvent() public {
        uint256 amount = 500 ether;

        vm.expectEmit(true, true, true, true);
        emit FleetTreasuryPaymaster.TokensWithdrawn(address(bondToken), withdrawer, amount);

        vm.prank(withdrawer);
        paymaster.withdrawTokens(address(bondToken), withdrawer, amount);
    }
}
