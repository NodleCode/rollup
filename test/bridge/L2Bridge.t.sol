// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {L2Bridge} from "src/bridge/L2Bridge.sol";
import {IWithdrawalMessage} from "src/bridge/interfaces/IWithdrawalMessage.sol";
import {NODL} from "src/NODL.sol";
import {AddressAliasHelper} from "lib/era-contracts/l1-contracts/contracts/vendor/AddressAliasHelper.sol";
import {L2_MESSENGER} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract L2BridgeTest is Test {
    // Actors
    address internal ADMIN = address(0xA11CE);
    address internal L1_BRIDGE = address(0xB111D9E);
    address internal USER = address(0xBEEF);
    address internal OTHER = address(0xCAFE);

    // Deployed contracts
    NODL internal token;
    L2Bridge internal bridge;

    // Events (mirror interface for expectEmit)
    event DepositFinalized(address indexed l1Sender, address indexed l2Receiver, uint256 amount);
    event WithdrawalInitiated(address indexed l2Sender, address indexed l1Receiver, uint256 amount);

    function setUp() public {
        token = new NODL(ADMIN);
        bridge = new L2Bridge(ADMIN, address(token));

        vm.startPrank(ADMIN);

        bridge.initialize(L1_BRIDGE);

        token.grantRole(token.MINTER_ROLE(), address(bridge));
        token.mint(USER, 1_000_000 ether);

        vm.stopPrank();
    }

    // ============================
    // initialize & constructor
    // ============================
    function test_Initialize_HappyPath_SetsL1Bridge() public {
        vm.prank(ADMIN);
        assertEq(bridge.l1Bridge(), L1_BRIDGE, "L1 bridge set");
    }

    function test_Initialize_Revert_OnlyOwner() public {
        L2Bridge bridge2 = new L2Bridge(ADMIN, address(token));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        vm.prank(USER);
        bridge2.initialize(L1_BRIDGE);
    }

    function test_Initialize_Revert_ZeroAddress() public {
        L2Bridge bridge2 = new L2Bridge(ADMIN, address(token));
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.ZeroAddress.selector));
        vm.prank(ADMIN);
        bridge2.initialize(address(0));
    }

    function test_Initialize_Revert_AlreadyInitialized() public {
        L2Bridge bridge2 = new L2Bridge(ADMIN, address(token));
        vm.prank(ADMIN);
        bridge2.initialize(L1_BRIDGE);
        vm.expectRevert(L2Bridge.AlreadyInitialized.selector);
        vm.prank(ADMIN);
        bridge2.initialize(L1_BRIDGE);
    }

    function test_FinalizeDeposit_Revert_BeforeInitialize_Unauthorized() public {
        L2Bridge bridge2 = new L2Bridge(ADMIN, address(token));
        address aliased = AddressAliasHelper.applyL1ToL2Alias(L1_BRIDGE);
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.Unauthorized.selector, aliased));
        vm.prank(aliased);
        bridge2.finalizeDeposit(L1_BRIDGE, OTHER, 1 ether);
    }

    // ============================
    // finalizeDeposit
    // ============================
    function test_FinalizeDeposit_HappyPath() public {
        uint256 amount = 123 ether;
        address l2Receiver = OTHER;
        address aliased = AddressAliasHelper.applyL1ToL2Alias(L1_BRIDGE);

        vm.prank(aliased);
        vm.expectEmit(true, true, true, true);
        emit DepositFinalized(L1_BRIDGE, l2Receiver, amount);
        bridge.finalizeDeposit(L1_BRIDGE, l2Receiver, amount);

        assertEq(token.balanceOf(l2Receiver), amount, "minted on L2");
    }

    function test_FinalizeDeposit_Revert_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.Unauthorized.selector, USER));
        vm.prank(USER);
        bridge.finalizeDeposit(L1_BRIDGE, OTHER, 1);
    }

    function test_FinalizeDeposit_Revert_ZeroAddressArgs() public {
        address aliased = AddressAliasHelper.applyL1ToL2Alias(L1_BRIDGE);
        vm.prank(aliased);
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.ZeroAddress.selector));
        bridge.finalizeDeposit(address(0), OTHER, 1);

        vm.prank(aliased);
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.ZeroAddress.selector));
        bridge.finalizeDeposit(L1_BRIDGE, address(0), 1);
    }

    function test_FinalizeDeposit_Revert_ZeroAmount() public {
        address aliased = AddressAliasHelper.applyL1ToL2Alias(L1_BRIDGE);
        vm.prank(aliased);
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.ZeroAmount.selector));
        bridge.finalizeDeposit(L1_BRIDGE, OTHER, 0);
    }

    // ============================
    // withdraw
    // ============================
    function test_Withdraw_HappyPath() public {
        uint256 amount = 77 ether;
        address l1Receiver = address(0x1111);

        vm.startPrank(USER);
        token.approve(address(bridge), amount);

        bytes memory expected = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, l1Receiver, amount);
        // Mock the messenger call so it doesn't revert (precompile address has no code under forge)
        vm.mockCall(
            address(L2_MESSENGER), abi.encodeWithSignature("sendToL1(bytes)", expected), abi.encode(bytes32(uint256(1)))
        );
        vm.expectCall(address(L2_MESSENGER), abi.encodeWithSignature("sendToL1(bytes)", expected));

        vm.expectEmit(true, true, true, true);
        emit WithdrawalInitiated(USER, l1Receiver, amount);
        bridge.withdraw(l1Receiver, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(USER), 1_000_000 ether - amount, "burned on L2");
    }

    function test_Withdraw_Revert_ZeroAddress() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.ZeroAddress.selector));
        bridge.withdraw(address(0), 1);
    }

    function test_Withdraw_Revert_ZeroAmount() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.ZeroAmount.selector));
        bridge.withdraw(OTHER, 0);
    }

    // ============================
    // Pausable & OnlyOwner
    // ============================
    function test_Pause_Gates_Functions() public {
        vm.prank(ADMIN);
        bridge.pause();

        address aliased = AddressAliasHelper.applyL1ToL2Alias(L1_BRIDGE);
        vm.prank(aliased);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.finalizeDeposit(L1_BRIDGE, OTHER, 1);

        vm.prank(USER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bridge.withdraw(OTHER, 1);
    }

    function test_Unpause_Allows_Functions() public {
        vm.prank(ADMIN);
        bridge.pause();
        vm.prank(ADMIN);
        bridge.unpause();

        address aliased = AddressAliasHelper.applyL1ToL2Alias(L1_BRIDGE);
        vm.prank(aliased);
        bridge.finalizeDeposit(L1_BRIDGE, OTHER, 1);

        vm.prank(USER);
        token.approve(address(bridge), 1);
        bytes memory expected = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, OTHER, uint256(1));
        vm.mockCall(
            address(L2_MESSENGER), abi.encodeWithSignature("sendToL1(bytes)", expected), abi.encode(bytes32(uint256(1)))
        );
        vm.prank(USER);
        bridge.withdraw(OTHER, 1);
    }

    function test_Pause_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        vm.prank(USER);
        bridge.pause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(ADMIN);
        bridge.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        vm.prank(USER);
        bridge.unpause();
    }

    // ============================
    // Constructor
    // ============================
    function test_Constructor_Revert_ZeroAddress() public {
        // Ownable will revert with OwnableInvalidOwner if owner is zero
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new L2Bridge(address(0), address(token));
        // Our contract reverts with ZeroAddress if token is zero
        vm.expectRevert(abi.encodeWithSelector(L2Bridge.ZeroAddress.selector));
        new L2Bridge(ADMIN, address(0));
    }
}
