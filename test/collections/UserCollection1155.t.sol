// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {UserCollection1155} from "../../src/collections/UserCollection1155.sol";
import {IUserCollection1155} from "../../src/collections/interfaces/IUserCollection1155.sol";
import {CreateParams1155} from "../../src/collections/interfaces/CollectionTypes.sol";

contract UserCollection1155Test is Test {
    UserCollection1155 internal impl;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OPERATOR_MINTER = address(0xB0B);
    address internal constant ROYALTY_RECIPIENT = address(0xCAFE);
    address internal constant ALICE = address(0xA1);
    address internal constant STRANGER = address(0xDEAD);

    bytes32 internal constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    event TransferSingle(
        address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value
    );
    event TransferBatch(
        address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values
    );
    event MetadataLocked();
    event RoyaltiesLocked();
    event ContractURIUpdated(string newURI);
    event URIUpdated(string newURI);

    function setUp() public {
        impl = new UserCollection1155();
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _deployClone(uint96 royaltyBps, address[] memory additionalMinters)
        internal
        returns (UserCollection1155 clone)
    {
        address cloneAddr = address(new ERC1967Proxy(address(impl), ""));
        clone = UserCollection1155(cloneAddr);
        clone.initialize(
            CreateParams1155({
                owner: OWNER,
                uri: "ipfs://1155/{id}.json",
                contractURI: "ipfs://contract.json",
                royaltyRecipient: ROYALTY_RECIPIENT,
                royaltyBps: royaltyBps,
                additionalMinters: additionalMinters
            }),
            OPERATOR_MINTER
        );
    }

    function _deployCloneDefault() internal returns (UserCollection1155) {
        address[] memory empty = new address[](0);
        return _deployClone(500, empty);
    }

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    function test_initialize_setsAllFieldsAndRoles() public {
        address[] memory extras = new address[](1);
        extras[0] = ALICE;
        UserCollection1155 clone = _deployClone(750, extras);

        assertEq(clone.uri(0), "ipfs://1155/{id}.json");
        assertEq(clone.contractURI(), "ipfs://contract.json");
        assertFalse(clone.metadataLocked());
        assertFalse(clone.royaltiesLocked());

        assertTrue(clone.hasRole(OWNER_ROLE, OWNER));
        assertTrue(clone.hasRole(MINTER_ROLE, OWNER));
        assertTrue(clone.hasRole(MINTER_ROLE, OPERATOR_MINTER));
        assertTrue(clone.hasRole(MINTER_ROLE, ALICE));
        assertEq(clone.getRoleAdmin(MINTER_ROLE), OWNER_ROLE);

        (address recv, uint256 amount) = clone.royaltyInfo(0, 10_000);
        assertEq(recv, ROYALTY_RECIPIENT);
        assertEq(amount, 750);
    }

    function test_initialize_revertsOnZeroOwner() public {
        address cloneAddr = address(new ERC1967Proxy(address(impl), ""));
        address[] memory empty = new address[](0);
        vm.expectRevert(IUserCollection1155.ZeroAddress.selector);
        UserCollection1155(cloneAddr).initialize(
            CreateParams1155({
                owner: address(0),
                uri: "",
                contractURI: "",
                royaltyRecipient: address(0),
                royaltyBps: 0,
                additionalMinters: empty
            }),
            OPERATOR_MINTER
        );
    }

    function test_initialize_revertsOnZeroOperatorMinter() public {
        address cloneAddr = address(new ERC1967Proxy(address(impl), ""));
        address[] memory empty = new address[](0);
        vm.expectRevert(IUserCollection1155.ZeroAddress.selector);
        UserCollection1155(cloneAddr).initialize(
            CreateParams1155({
                owner: OWNER,
                uri: "",
                contractURI: "",
                royaltyRecipient: address(0),
                royaltyBps: 0,
                additionalMinters: empty
            }),
            address(0)
        );
    }

    function test_implementation_disablesInitializers() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            CreateParams1155({
                owner: OWNER,
                uri: "",
                contractURI: "",
                royaltyRecipient: address(0),
                royaltyBps: 0,
                additionalMinters: empty
            }),
            OPERATOR_MINTER
        );
    }

    // ──────────────────────────────────────────────
    // Mint
    // ──────────────────────────────────────────────

    function test_mint_assignsBalanceAndEmits() public {
        UserCollection1155 clone = _deployCloneDefault();

        vm.expectEmit(true, true, true, true);
        emit TransferSingle(OPERATOR_MINTER, address(0), ALICE, 42, 5);

        vm.prank(OPERATOR_MINTER);
        clone.mint(ALICE, 42, 5, "");
        assertEq(clone.balanceOf(ALICE, 42), 5);
        assertEq(clone.totalSupply(42), 5);
    }

    function test_mint_revertsForNonMinter() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, MINTER_ROLE)
        );
        vm.prank(STRANGER);
        clone.mint(ALICE, 0, 1, "");
    }

    function test_mintBatch_singleRecipientUpdatesBalances() public {
        UserCollection1155 clone = _deployCloneDefault();
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;
        amounts[0] = 10; amounts[1] = 20; amounts[2] = 30;

        vm.expectEmit(true, true, true, true);
        emit TransferBatch(OPERATOR_MINTER, address(0), ALICE, ids, amounts);

        vm.prank(OPERATOR_MINTER);
        clone.mintBatch(ALICE, ids, amounts, "");

        assertEq(clone.balanceOf(ALICE, 1), 10);
        assertEq(clone.balanceOf(ALICE, 2), 20);
        assertEq(clone.balanceOf(ALICE, 3), 30);
    }

    function test_mintBatch_revertsLengthMismatch() public {
        UserCollection1155 clone = _deployCloneDefault();
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1; ids[1] = 2; amounts[0] = 1;
        vm.expectRevert(IUserCollection1155.LengthMismatch.selector);
        vm.prank(OPERATOR_MINTER);
        clone.mintBatch(ALICE, ids, amounts, "");
    }

    function test_mintBatch_revertsOversize() public {
        UserCollection1155 clone = _deployCloneDefault();
        uint256[] memory ids = new uint256[](101);
        uint256[] memory amounts = new uint256[](101);
        for (uint256 i = 0; i < 101; ++i) { ids[i] = i; amounts[i] = 1; }
        vm.expectRevert(abi.encodeWithSelector(IUserCollection1155.BatchTooLarge.selector, 101, 100));
        vm.prank(OPERATOR_MINTER);
        clone.mintBatch(ALICE, ids, amounts, "");
    }

    // ──────────────────────────────────────────────
    // Owner-mutable settings + locks
    // ──────────────────────────────────────────────

    function test_setURI_updatesAndEmits() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit URIUpdated("ipfs://new/{id}.json");
        vm.prank(OWNER);
        clone.setURI("ipfs://new/{id}.json");
        assertEq(clone.uri(123), "ipfs://new/{id}.json");
    }

    function test_lockMetadata_blocksSubsequentSetters() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit MetadataLocked();
        vm.prank(OWNER);
        clone.lockMetadata();

        vm.prank(OWNER);
        vm.expectRevert(IUserCollection1155.MetadataIsLocked.selector);
        clone.setURI("x");

        vm.prank(OWNER);
        vm.expectRevert(IUserCollection1155.MetadataIsLocked.selector);
        clone.setContractURI("x");
    }

    function test_lockRoyalties_blocksSubsequentSetters() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit RoyaltiesLocked();
        vm.prank(OWNER);
        clone.lockRoyalties();

        vm.prank(OWNER);
        vm.expectRevert(IUserCollection1155.RoyaltiesAreLocked.selector);
        clone.setDefaultRoyalty(ALICE, 100);
    }

    function test_setContractURI_emitsAndUpdates() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit ContractURIUpdated("ipfs://newcontract.json");
        vm.prank(OWNER);
        clone.setContractURI("ipfs://newcontract.json");
        assertEq(clone.contractURI(), "ipfs://newcontract.json");
    }

    function test_setDefaultRoyalty_zeroBpsClears() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.prank(OWNER);
        clone.setDefaultRoyalty(address(0), 0);
        (address recv, uint256 amount) = clone.royaltyInfo(0, 10_000);
        assertEq(recv, address(0));
        assertEq(amount, 0);
    }

    function test_setDefaultRoyalty_nonZeroBpsUpdates() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.prank(OWNER);
        clone.setDefaultRoyalty(ALICE, 1000);
        (address recv, uint256 amount) = clone.royaltyInfo(0, 10_000);
        assertEq(recv, ALICE);
        assertEq(amount, 1000);
    }

    function test_owner_canRevokeOperatorMinter() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.prank(OWNER);
        clone.revokeRole(MINTER_ROLE, OPERATOR_MINTER);

        vm.prank(OPERATOR_MINTER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR_MINTER, MINTER_ROLE
            )
        );
        clone.mint(ALICE, 1, 1, "");
    }

    // ──────────────────────────────────────────────
    // ERC-2981 + supportsInterface
    // ──────────────────────────────────────────────

    function test_supportsInterface_advertisesAllExpectedIds() public {
        UserCollection1155 clone = _deployCloneDefault();
        assertTrue(clone.supportsInterface(type(IERC165).interfaceId));
        assertTrue(clone.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(clone.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertTrue(clone.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(clone.supportsInterface(type(IAccessControl).interfaceId));
    }

    // ──────────────────────────────────────────────
    // Burn + supply (ERC1155Burnable + ERC1155Supply)
    // ──────────────────────────────────────────────

    function test_burn_decrementsSupplyAndBalance() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.prank(OPERATOR_MINTER);
        clone.mint(ALICE, 1, 5, "");
        assertEq(clone.totalSupply(1), 5);

        vm.prank(ALICE);
        clone.burn(ALICE, 1, 2);
        assertEq(clone.balanceOf(ALICE, 1), 3);
        assertEq(clone.totalSupply(1), 3);
    }

    function test_burn_revertsForUnauthorized() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.prank(OPERATOR_MINTER);
        clone.mint(ALICE, 1, 5, "");

        vm.prank(STRANGER);
        vm.expectRevert();
        clone.burn(ALICE, 1, 1);
    }

    function test_supply_tracksAcrossMintAndMintBatch() public {
        UserCollection1155 clone = _deployCloneDefault();
        vm.prank(OPERATOR_MINTER);
        clone.mint(ALICE, 1, 10, "");

        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        amounts[0] = 5; amounts[1] = 7;
        vm.prank(OPERATOR_MINTER);
        clone.mintBatch(ALICE, ids, amounts, "");

        assertEq(clone.totalSupply(1), 15);
        assertEq(clone.totalSupply(2), 7);
    }

    // ──────────────────────────────────────────────
    // Bytecode permanence (§7.2 row 15, §8.3)
    // ──────────────────────────────────────────────

    function test_implementation_runtimeCode_containsNoSelfdestruct() public view {
        bytes memory code = address(impl).code;
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xff, "SELFDESTRUCT opcode at runtime position");
            if (op >= 0x60 && op <= 0x7f) {
                i += 1 + (op - 0x5f);
            } else {
                i += 1;
            }
        }
    }

    function test_implementationHasNoUpgradeSelectors() public view {
        // proxiableUUID() — selector 0x52d1902d
        (bool ok1, ) = address(impl).staticcall(abi.encodeWithSelector(0x52d1902d));
        assertFalse(ok1, "impl must not expose proxiableUUID");

        // upgradeToAndCall(address,bytes) — selector 0x4f1ef286
        (bool ok2, ) = address(impl).staticcall(
            abi.encodeWithSelector(0x4f1ef286, address(0), bytes(""))
        );
        assertFalse(ok2, "impl must not expose upgradeToAndCall");
    }
}
