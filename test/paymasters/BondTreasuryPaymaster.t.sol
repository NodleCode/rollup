// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlUtils} from "../__helpers__/AccessControlUtils.sol";
import {BasePaymaster} from "../../src/paymasters/BasePaymaster.sol";
import {BondTreasuryPaymaster} from "../../src/paymasters/BondTreasuryPaymaster.sol";
import {WhitelistPaymaster} from "../../src/paymasters/WhitelistPaymaster.sol";
import {QuotaControl} from "../../src/QuotaControl.sol";
import {FleetIdentityUpgradeable} from "../../src/swarms/FleetIdentityUpgradeable.sol";

contract MockERC20SCP is ERC20 {
    constructor() ERC20("Mock Bond Token", "MBOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Any whitelisted contract can pull bond after `consumeSponsoredBond` (integration helper).
contract SponsoredBondPuller {
    BondTreasuryPaymaster public immutable paymaster;
    IERC20 public immutable token;

    constructor(BondTreasuryPaymaster paymaster_, IERC20 token_) {
        paymaster = paymaster_;
        token = token_;
    }

    function pullBond(address user, uint256 amount) external {
        paymaster.consumeSponsoredBond(user, amount);
        token.transferFrom(address(paymaster), address(this), amount);
    }
}

/// @dev Exposes internal paymaster validation for unit testing.
contract MockBondTreasuryPaymaster is BondTreasuryPaymaster {
    constructor(
        address admin,
        address whitelistAdmin,
        address withdrawer,
        address[] memory initialWhitelistedContracts,
        address[] memory initialWhitelistedUsers,
        address bondToken_,
        uint256 initialQuota,
        uint256 initialPeriod
    )
        BondTreasuryPaymaster(
            admin,
            whitelistAdmin,
            withdrawer,
            initialWhitelistedContracts,
            initialWhitelistedUsers,
            bondToken_,
            initialQuota,
            initialPeriod
        )
    {}

    function mock_validateAndPayGeneralFlow(address from, address to, uint256 requiredETH) public view {
        _validateAndPayGeneralFlow(from, to, requiredETH);
    }

    function mock_validateAndPayApprovalBasedFlow(
        address from,
        address to,
        address token_,
        uint256 amount,
        bytes memory data,
        uint256 requiredETH
    ) public pure {
        _validateAndPayApprovalBasedFlow(from, to, token_, amount, data, requiredETH);
    }
}

contract BondTreasuryPaymasterTest is Test {
    using AccessControlUtils for Vm;

    FleetIdentityUpgradeable fleet;
    MockBondTreasuryPaymaster paymaster;
    MockERC20SCP bondToken;

    address internal admin = address(0x1111);
    address internal withdrawer = address(0x2222);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal attacker = address(0xB33F);

    bytes16 constant UUID_1 = bytes16(keccak256("fleet-alpha"));
    bytes16 constant UUID_2 = bytes16(keccak256("fleet-bravo"));
    bytes16 constant UUID_3 = bytes16(keccak256("fleet-charlie"));

    uint256 constant BASE_BOND = 100 ether;
    uint256 constant QUOTA = 1000 ether;
    uint256 constant PERIOD = 1 days;

    address[] internal whitelistTargets;

    function _initialContractWhitelist(address fleetAddr) internal pure returns (address[] memory) {
        address[] memory c = new address[](1);
        c[0] = fleetAddr;
        return c;
    }

    function _emptyAddresses() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _singleAddress(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function setUp() public {
        bondToken = new MockERC20SCP();

        FleetIdentityUpgradeable impl = new FleetIdentityUpgradeable();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FleetIdentityUpgradeable.initialize, (admin, address(bondToken), BASE_BOND, 0))
        );
        fleet = FleetIdentityUpgradeable(address(proxy));

        address[] memory initialUsers = new address[](2);
        initialUsers[0] = alice;
        initialUsers[1] = admin;

        paymaster = new MockBondTreasuryPaymaster(
            admin,
            admin,
            withdrawer,
            _initialContractWhitelist(address(fleet)),
            initialUsers,
            address(bondToken),
            QUOTA,
            PERIOD
        );

        bondToken.mint(address(paymaster), 10_000 ether);
        whitelistTargets = new address[](1);
        whitelistTargets[0] = alice;
    }

    // ══════════════════════════════════════════════
    // ACLs & Immutables
    // ══════════════════════════════════════════════

    function test_defaultACLs() public view {
        assertTrue(paymaster.hasRole(paymaster.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(paymaster.hasRole(paymaster.WHITELIST_ADMIN_ROLE(), admin));
        assertTrue(paymaster.hasRole(paymaster.WITHDRAWER_ROLE(), withdrawer));
    }

    function test_separateWhitelistAdmin() public {
        address whitelistAdmin = address(0x3333);
        MockBondTreasuryPaymaster pm = new MockBondTreasuryPaymaster(
            admin,
            whitelistAdmin,
            withdrawer,
            _initialContractWhitelist(address(fleet)),
            _emptyAddresses(),
            address(bondToken),
            QUOTA,
            PERIOD
        );
        assertTrue(pm.hasRole(pm.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(pm.hasRole(pm.WHITELIST_ADMIN_ROLE(), admin));
        assertTrue(pm.hasRole(pm.WHITELIST_ADMIN_ROLE(), whitelistAdmin));
        assertTrue(pm.hasRole(pm.WITHDRAWER_ROLE(), withdrawer));
        assertFalse(pm.hasRole(pm.DEFAULT_ADMIN_ROLE(), whitelistAdmin));
    }

    function test_immutables() public view {
        assertEq(address(paymaster.bondToken()), address(bondToken));
    }

    function test_initialWhitelistedContractIncludesFleet() public view {
        assertTrue(paymaster.isWhitelistedContract(address(fleet)));
    }

    function test_paymasterSelfSeededAsWhitelistedContract() public view {
        assertTrue(paymaster.isWhitelistedContract(address(paymaster)));
    }

    function test_initialWhitelistedUsersSetInConstructor() public view {
        assertTrue(paymaster.isWhitelistedUser(alice));
        assertTrue(paymaster.isWhitelistedUser(admin));
    }

    function test_constructorWithEmptyWhitelistedUsers() public {
        MockBondTreasuryPaymaster pm = new MockBondTreasuryPaymaster(
            admin,
            admin,
            withdrawer,
            _initialContractWhitelist(address(fleet)),
            _emptyAddresses(),
            address(bondToken),
            QUOTA,
            PERIOD
        );
        assertFalse(pm.isWhitelistedUser(alice));
        assertFalse(pm.isWhitelistedUser(admin));
    }

    function test_constructorWithMultipleWhitelistedUsers() public {
        address charlie = address(0xC);
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        MockBondTreasuryPaymaster pm = new MockBondTreasuryPaymaster(
            admin, admin, withdrawer, _initialContractWhitelist(address(fleet)), users, address(bondToken), QUOTA, PERIOD
        );
        assertTrue(pm.isWhitelistedUser(alice));
        assertTrue(pm.isWhitelistedUser(bob));
        assertTrue(pm.isWhitelistedUser(charlie));
    }

    function test_constructorEmitsWhitelistedUsersAdded() public {
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;

        vm.expectEmit();
        emit WhitelistPaymaster.WhitelistedUsersAdded(users);
        new MockBondTreasuryPaymaster(
            admin, admin, withdrawer, _initialContractWhitelist(address(fleet)), users, address(bondToken), QUOTA, PERIOD
        );
    }

    function test_constructorEmptyUsersDoesNotEmitEvent() public {
        vm.recordLogs();
        new MockBondTreasuryPaymaster(
            admin,
            admin,
            withdrawer,
            _initialContractWhitelist(address(fleet)),
            _emptyAddresses(),
            address(bondToken),
            QUOTA,
            PERIOD
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 usersAddedTopic = WhitelistPaymaster.WhitelistedUsersAdded.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != usersAddedTopic, "Should not emit WhitelistedUsersAdded for empty array");
        }
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
        emit WhitelistPaymaster.WhitelistedUsersAdded(targets);
        paymaster.addWhitelistedUsers(targets);
        assertTrue(paymaster.isWhitelistedUser(bob));

        vm.expectEmit();
        emit WhitelistPaymaster.WhitelistedUsersRemoved(targets);
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

    function test_RevertIf_nonWhitelistedUser_toPaymaster() public {
        vm.deal(address(paymaster), 10 ether);
        vm.expectRevert(WhitelistPaymaster.UserIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(bob, address(paymaster), 1 ether);
    }

    function test_RevertIf_adminToSelf_paymasterBalanceTooLow() public {
        vm.expectRevert(WhitelistPaymaster.PaymasterBalanceTooLow.selector);
        paymaster.mock_validateAndPayGeneralFlow(admin, address(paymaster), 1 ether);
    }

    function test_doesNotSupportApprovalBasedFlow() public {
        vm.expectRevert(BasePaymaster.PaymasterFlowNotSupported.selector);
        paymaster.mock_validateAndPayApprovalBasedFlow(alice, address(fleet), address(0), 1, "0x", 0);
    }

    function test_RevertIf_destIsNotWhitelisted() public {
        vm.expectRevert(WhitelistPaymaster.DestIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(alice, address(0xDEAD), 0);
    }

    function test_generalFlowValidation_whitelistedContract_success() public {
        address extra = address(0xCAFE);
        address[] memory contracts_ = new address[](1);
        contracts_[0] = extra;
        vm.prank(admin);
        paymaster.addWhitelistedContracts(contracts_);
        assertTrue(paymaster.isWhitelistedContract(extra));

        vm.deal(address(paymaster), 10 ether);
        paymaster.mock_validateAndPayGeneralFlow(alice, extra, 1 ether);
    }

    function test_RevertIf_whitelistedContract_userNotWhitelisted() public {
        address extra = address(0xCAFE);
        address[] memory contracts_ = new address[](1);
        contracts_[0] = extra;
        vm.prank(admin);
        paymaster.addWhitelistedContracts(contracts_);

        vm.expectRevert(WhitelistPaymaster.UserIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(bob, extra, 0);
    }

    function test_whitelistAdminUpdatesContractWhitelist() public {
        address extra = address(0xBEEF);
        address[] memory contracts_ = new address[](1);
        contracts_[0] = extra;

        vm.startPrank(admin);
        vm.expectEmit();
        emit WhitelistPaymaster.WhitelistedContractsAdded(contracts_);
        paymaster.addWhitelistedContracts(contracts_);
        assertTrue(paymaster.isWhitelistedContract(extra));

        vm.expectEmit();
        emit WhitelistPaymaster.WhitelistedContractsRemoved(contracts_);
        paymaster.removeWhitelistedContracts(contracts_);
        assertFalse(paymaster.isWhitelistedContract(extra));
        vm.stopPrank();
    }

    function test_removeWhitelistedContract_canRemoveFleet() public {
        address[] memory contracts_ = new address[](1);
        contracts_[0] = address(fleet);
        vm.prank(admin);
        paymaster.removeWhitelistedContracts(contracts_);
        assertFalse(paymaster.isWhitelistedContract(address(fleet)));
    }

    function test_RevertIf_userIsNotWhitelisted_paymaster() public {
        vm.expectRevert(WhitelistPaymaster.UserIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(bob, address(fleet), 0);
    }

    function test_RevertIf_paymasterBalanceTooLow() public {
        vm.expectRevert(WhitelistPaymaster.PaymasterBalanceTooLow.selector);
        paymaster.mock_validateAndPayGeneralFlow(alice, address(fleet), 1 ether);
    }

    // ══════════════════════════════════════════════
    // Treasury: consumeSponsoredBond
    // ══════════════════════════════════════════════

    function test_consumeSponsoredBond_success() public {
        vm.prank(address(fleet));
        paymaster.consumeSponsoredBond(alice, BASE_BOND);
        assertEq(paymaster.claimed(), BASE_BOND);
    }

    function test_consumeSponsoredBond_anyWhitelistedContract() public {
        SponsoredBondPuller puller = new SponsoredBondPuller(paymaster, IERC20(address(bondToken)));
        address[] memory contracts_ = new address[](1);
        contracts_[0] = address(puller);
        vm.prank(admin);
        paymaster.addWhitelistedContracts(contracts_);

        uint256 beforePm = bondToken.balanceOf(address(paymaster));
        puller.pullBond(alice, BASE_BOND);
        assertEq(bondToken.balanceOf(address(puller)), BASE_BOND);
        assertEq(bondToken.balanceOf(address(paymaster)), beforePm - BASE_BOND);
        assertEq(paymaster.claimed(), BASE_BOND);
    }

    function test_RevertIf_consumeSponsoredBond_callerNotWhitelistedContract() public {
        vm.prank(alice);
        vm.expectRevert(BondTreasuryPaymaster.CallerNotWhitelistedContract.selector);
        paymaster.consumeSponsoredBond(alice, BASE_BOND);
    }

    function test_RevertIf_consumeSponsoredBond_notWhitelisted() public {
        vm.prank(address(fleet));
        vm.expectRevert(WhitelistPaymaster.UserIsNotWhitelisted.selector);
        paymaster.consumeSponsoredBond(bob, BASE_BOND);
    }

    function test_RevertIf_consumeSponsoredBond_insufficientBalance() public {
        vm.startPrank(withdrawer);
        paymaster.withdrawTokens(address(bondToken), withdrawer, bondToken.balanceOf(address(paymaster)));
        vm.stopPrank();

        vm.prank(address(fleet));
        vm.expectRevert(BondTreasuryPaymaster.InsufficientBondBalance.selector);
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

        for (uint256 i = 0; i < 10; i++) {
            bytes16 uuid = bytes16(keccak256(abi.encodePacked("uuid-", i)));
            vm.prank(alice);
            fleet.claimUuidSponsored(uuid, address(0), address(paymaster));
        }

        vm.prank(alice);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        fleet.claimUuidSponsored(UUID_3, address(0), address(paymaster));
    }

    function test_quotaTracksBaseBondNotClaimCount() public {
        MockBondTreasuryPaymaster tightPaymaster = new MockBondTreasuryPaymaster(
            admin,
            admin,
            withdrawer,
            _initialContractWhitelist(address(fleet)),
            _singleAddress(alice),
            address(bondToken),
            BASE_BOND / 2,
            PERIOD
        );

        bondToken.mint(address(tightPaymaster), 10_000 ether);

        vm.prank(alice);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        fleet.claimUuidSponsored(UUID_1, address(0), address(tightPaymaster));
    }

    function test_quotaResetsAfterPeriod() public {
        bondToken.mint(address(paymaster), 100_000 ether);

        for (uint256 i = 0; i < 10; i++) {
            bytes16 uuid = bytes16(keccak256(abi.encodePacked("uuid-", i)));
            vm.prank(alice);
            fleet.claimUuidSponsored(uuid, address(0), address(paymaster));
        }

        vm.prank(alice);
        vm.expectRevert(QuotaControl.QuotaExceeded.selector);
        fleet.claimUuidSponsored(UUID_3, address(0), address(paymaster));

        vm.warp(block.timestamp + PERIOD + 1);

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
        new MockBondTreasuryPaymaster(
            admin,
            admin,
            withdrawer,
            _initialContractWhitelist(address(fleet)),
            _emptyAddresses(),
            address(bondToken),
            QUOTA,
            0
        );
    }

    function test_RevertIf_constructorTooLongPeriod() public {
        vm.expectRevert(QuotaControl.TooLongPeriod.selector);
        new MockBondTreasuryPaymaster(
            admin,
            admin,
            withdrawer,
            _initialContractWhitelist(address(fleet)),
            _emptyAddresses(),
            address(bondToken),
            QUOTA,
            31 days
        );
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
        emit BondTreasuryPaymaster.TokensWithdrawn(address(bondToken), withdrawer, amount);

        vm.prank(withdrawer);
        paymaster.withdrawTokens(address(bondToken), withdrawer, amount);
    }

    // ══════════════════════════════════════════════
    // Security: deployment & access boundaries
    // ══════════════════════════════════════════════

    function test_RevertIf_attacker_cannot_mutate_whitelists() public {
        vm.startPrank(attacker);
        vm.expectRevert_AccessControlUnauthorizedAccount(attacker, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.addWhitelistedUsers(whitelistTargets);
        vm.expectRevert_AccessControlUnauthorizedAccount(attacker, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.removeWhitelistedUsers(whitelistTargets);
        address[] memory c = new address[](1);
        c[0] = address(fleet);
        vm.expectRevert_AccessControlUnauthorizedAccount(attacker, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.addWhitelistedContracts(c);
        vm.expectRevert_AccessControlUnauthorizedAccount(attacker, paymaster.WHITELIST_ADMIN_ROLE());
        paymaster.removeWhitelistedContracts(c);
        vm.stopPrank();
    }

    function test_RevertIf_attacker_cannot_withdrawTokens() public {
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.withdrawTokens(address(bondToken), attacker, 1 ether);
    }

    function test_RevertIf_attacker_cannot_withdrawETH() public {
        vm.deal(address(paymaster), 1 ether);
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.withdraw(attacker, 1 ether);
    }

    function test_RevertIf_admin_cannot_withdrawETH_without_withdrawer_role() public {
        vm.deal(address(paymaster), 1 ether);
        vm.prank(admin);
        vm.expectRevert();
        paymaster.withdraw(admin, 1 ether);
    }

    function test_RevertIf_removePaymasterFromWhitelist_blocksSponsoredSelfValidation() public {
        vm.deal(address(paymaster), 10 ether);
        address[] memory self = new address[](1);
        self[0] = address(paymaster);
        vm.prank(admin);
        paymaster.removeWhitelistedContracts(self);

        vm.expectRevert(WhitelistPaymaster.DestIsNotWhitelisted.selector);
        paymaster.mock_validateAndPayGeneralFlow(admin, address(paymaster), 1 ether);
    }

    function test_RevertIf_whitelistedBondPuller_cannot_change_whitelists() public {
        SponsoredBondPuller puller = new SponsoredBondPuller(paymaster, IERC20(address(bondToken)));
        address[] memory contracts_ = new address[](1);
        contracts_[0] = address(puller);
        vm.prank(admin);
        paymaster.addWhitelistedContracts(contracts_);

        vm.expectRevert_AccessControlUnauthorizedAccount(address(puller), paymaster.WHITELIST_ADMIN_ROLE());
        vm.prank(address(puller));
        paymaster.addWhitelistedUsers(whitelistTargets);
    }
}
