// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {UserCollection721} from "../../src/collections/UserCollection721.sol";
import {IUserCollection721} from "../../src/collections/interfaces/IUserCollection721.sol";
import {CreateParams721} from "../../src/collections/interfaces/CollectionTypes.sol";

contract UserCollection721Test is Test {
    UserCollection721 internal impl;

    address internal constant OWNER = address(0xA11CE);
    address internal constant OPERATOR_MINTER = address(0xB0B);
    address internal constant ROYALTY_RECIPIENT = address(0xCAFE);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant STRANGER = address(0xDEAD);

    bytes32 internal constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event MetadataLocked();
    event RoyaltiesLocked();
    event ContractURIUpdated(string newURI);
    event BaseURIUpdated(string newBase);

    function setUp() public {
        impl = new UserCollection721();
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _deployClone(uint96 royaltyBps, address[] memory additionalMinters)
        internal
        returns (UserCollection721 clone)
    {
        address cloneAddr = address(new ERC1967Proxy(address(impl), ""));
        clone = UserCollection721(cloneAddr);
        clone.initialize(
            CreateParams721({
                owner: OWNER,
                name: "Test Collection",
                symbol: "TC",
                baseURI: "ipfs://base/",
                contractURI: "ipfs://contract.json",
                royaltyRecipient: ROYALTY_RECIPIENT,
                royaltyBps: royaltyBps,
                additionalMinters: additionalMinters
            }),
            OPERATOR_MINTER
        );
    }

    function _deployCloneDefault() internal returns (UserCollection721) {
        address[] memory empty = new address[](0);
        return _deployClone(500, empty);
    }

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    function test_initialize_setsAllFieldsAndRoles() public {
        address[] memory extras = new address[](1);
        extras[0] = ALICE;
        UserCollection721 clone = _deployClone(750, extras);

        assertEq(clone.name(), "Test Collection");
        assertEq(clone.symbol(), "TC");
        assertEq(clone.contractURI(), "ipfs://contract.json");
        assertEq(clone.nextTokenId(), 0);
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
        vm.expectRevert(IUserCollection721.ZeroAddress.selector);
        UserCollection721(cloneAddr).initialize(
            CreateParams721({
                owner: address(0),
                name: "X",
                symbol: "X",
                baseURI: "",
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
        vm.expectRevert(IUserCollection721.ZeroAddress.selector);
        UserCollection721(cloneAddr).initialize(
            CreateParams721({
                owner: OWNER,
                name: "X",
                symbol: "X",
                baseURI: "",
                contractURI: "",
                royaltyRecipient: address(0),
                royaltyBps: 0,
                additionalMinters: empty
            }),
            address(0)
        );
    }

    function test_initialize_skipsRoyaltyWhenBpsZero() public {
        address[] memory empty = new address[](0);
        UserCollection721 clone = _deployClone(0, empty);
        (address recv, uint256 amount) = clone.royaltyInfo(0, 10_000);
        assertEq(recv, address(0));
        assertEq(amount, 0);
    }

    function test_implementation_disablesInitializers() public {
        // The implementation contract itself must not be initializable.
        address[] memory empty = new address[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(
            CreateParams721({
                owner: OWNER,
                name: "X",
                symbol: "X",
                baseURI: "",
                contractURI: "",
                royaltyRecipient: address(0),
                royaltyBps: 0,
                additionalMinters: empty
            }),
            OPERATOR_MINTER
        );
    }

    function test_initialize_revertsOnSecondCall() public {
        UserCollection721 clone = _deployCloneDefault();
        address[] memory empty = new address[](0);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        clone.initialize(
            CreateParams721({
                owner: OWNER,
                name: "X",
                symbol: "X",
                baseURI: "",
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

    function test_mint_assignsIdAndUriAndIncrementsCounter() public {
        UserCollection721 clone = _deployCloneDefault();

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), ALICE, 0);

        vm.prank(OPERATOR_MINTER);
        uint256 id = clone.mint(ALICE, "ipfs://0.json");

        assertEq(id, 0);
        assertEq(clone.nextTokenId(), 1);
        assertEq(clone.ownerOf(0), ALICE);
        assertEq(clone.tokenURI(0), "ipfs://base/ipfs://0.json");
    }

    function test_mint_revertsForNonMinter() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, MINTER_ROLE)
        );
        vm.prank(STRANGER);
        clone.mint(ALICE, "ipfs://0.json");
    }

    // ──────────────────────────────────────────────
    // mintBatch
    // ──────────────────────────────────────────────

    function test_mintBatch_returnsContiguousIdsAndMatchesTransfers() public {
        UserCollection721 clone = _deployCloneDefault();

        // Pre-seed one token so the batch starts at id 1.
        vm.prank(OPERATOR_MINTER);
        clone.mint(ALICE, "first.json");

        address[] memory recipients = new address[](3);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        recipients[2] = ALICE;
        string[] memory uris = new string[](3);
        uris[0] = "1.json";
        uris[1] = "2.json";
        uris[2] = "3.json";

        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), ALICE, 1);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), BOB, 2);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), ALICE, 3);

        vm.prank(OPERATOR_MINTER);
        uint256[] memory ids = clone.mintBatch(recipients, uris);

        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 3);
        assertEq(clone.nextTokenId(), 4);
    }

    function test_mintBatch_revertsLengthMismatch() public {
        UserCollection721 clone = _deployCloneDefault();
        address[] memory recipients = new address[](2);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        string[] memory uris = new string[](1);
        uris[0] = "x";
        vm.expectRevert(IUserCollection721.LengthMismatch.selector);
        vm.prank(OPERATOR_MINTER);
        clone.mintBatch(recipients, uris);
    }

    function test_mintBatch_revertsOversize() public {
        UserCollection721 clone = _deployCloneDefault();
        address[] memory recipients = new address[](101);
        string[] memory uris = new string[](101);
        for (uint256 i = 0; i < 101; ++i) {
            recipients[i] = ALICE;
            uris[i] = "x";
        }
        vm.expectRevert(abi.encodeWithSelector(IUserCollection721.BatchTooLarge.selector, 101, 100));
        vm.prank(OPERATOR_MINTER);
        clone.mintBatch(recipients, uris);
    }

    // ──────────────────────────────────────────────
    // Owner-mutable settings + locks
    // ──────────────────────────────────────────────

    function test_setBaseURI_emitsAndUpdates() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit BaseURIUpdated("ipfs://newbase/");
        vm.prank(OWNER);
        clone.setBaseURI("ipfs://newbase/");

        vm.prank(OPERATOR_MINTER);
        uint256 id = clone.mint(ALICE, "0.json");
        assertEq(clone.tokenURI(id), "ipfs://newbase/0.json");
    }

    function test_setBaseURI_revertsForNonOwner() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, OWNER_ROLE)
        );
        vm.prank(STRANGER);
        clone.setBaseURI("x");
    }

    function test_lockMetadata_blocksSubsequentSetters() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit MetadataLocked();
        vm.prank(OWNER);
        clone.lockMetadata();
        assertTrue(clone.metadataLocked());

        vm.prank(OWNER);
        vm.expectRevert(IUserCollection721.MetadataIsLocked.selector);
        clone.setBaseURI("x");

        vm.prank(OWNER);
        vm.expectRevert(IUserCollection721.MetadataIsLocked.selector);
        clone.setContractURI("x");
    }

    function test_lockRoyalties_blocksSubsequentSetters() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit RoyaltiesLocked();
        vm.prank(OWNER);
        clone.lockRoyalties();
        assertTrue(clone.royaltiesLocked());

        vm.prank(OWNER);
        vm.expectRevert(IUserCollection721.RoyaltiesAreLocked.selector);
        clone.setDefaultRoyalty(ALICE, 100);
    }

    function test_setDefaultRoyalty_zeroBpsClears() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.prank(OWNER);
        clone.setDefaultRoyalty(address(0), 0);
        (address recv, uint256 amount) = clone.royaltyInfo(0, 10_000);
        assertEq(recv, address(0));
        assertEq(amount, 0);
    }

    function test_setDefaultRoyalty_nonZeroBpsUpdates() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.prank(OWNER);
        clone.setDefaultRoyalty(ALICE, 1000);
        (address recv, uint256 amount) = clone.royaltyInfo(0, 10_000);
        assertEq(recv, ALICE);
        assertEq(amount, 1000);
    }

    function test_setContractURI_emitsAndUpdates() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.expectEmit(true, true, true, true);
        emit ContractURIUpdated("ipfs://newcontract.json");
        vm.prank(OWNER);
        clone.setContractURI("ipfs://newcontract.json");
        assertEq(clone.contractURI(), "ipfs://newcontract.json");
    }

    // ──────────────────────────────────────────────
    // Role admin
    // ──────────────────────────────────────────────

    function test_owner_canGrantAndRevokeMinterRole() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.prank(OWNER);
        clone.grantRole(MINTER_ROLE, ALICE);
        assertTrue(clone.hasRole(MINTER_ROLE, ALICE));

        vm.prank(OWNER);
        clone.revokeRole(MINTER_ROLE, OPERATOR_MINTER);
        assertFalse(clone.hasRole(MINTER_ROLE, OPERATOR_MINTER));

        vm.prank(OPERATOR_MINTER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR_MINTER, MINTER_ROLE)
        );
        clone.mint(ALICE, "x");
    }

    // ──────────────────────────────────────────────
    // ERC-2981 + supportsInterface
    // ──────────────────────────────────────────────

    function test_supportsInterface_advertisesAllExpectedIds() public {
        UserCollection721 clone = _deployCloneDefault();
        assertTrue(clone.supportsInterface(type(IERC165).interfaceId));
        assertTrue(clone.supportsInterface(type(IERC721).interfaceId));
        assertTrue(clone.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(clone.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(clone.supportsInterface(type(IAccessControl).interfaceId));
    }

    // ──────────────────────────────────────────────
    // Burn (ERC721Burnable)
    // ──────────────────────────────────────────────

    function test_burn_byOwnerRemovesToken() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.prank(OPERATOR_MINTER);
        uint256 id = clone.mint(ALICE, "0.json");

        vm.prank(ALICE);
        clone.burn(id);

        vm.expectRevert();
        clone.ownerOf(id);
    }

    function test_burn_revertsForUnauthorized() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.prank(OPERATOR_MINTER);
        uint256 id = clone.mint(ALICE, "0.json");

        vm.prank(STRANGER);
        vm.expectRevert();
        clone.burn(id);
    }

    function test_nextTokenId_isMonotonicAcrossSingleAndBatch() public {
        UserCollection721 clone = _deployCloneDefault();
        vm.prank(OPERATOR_MINTER);
        clone.mint(ALICE, "a");
        assertEq(clone.nextTokenId(), 1);

        address[] memory recipients = new address[](2);
        recipients[0] = ALICE;
        recipients[1] = BOB;
        string[] memory uris = new string[](2);
        uris[0] = "b"; uris[1] = "c";
        vm.prank(OPERATOR_MINTER);
        clone.mintBatch(recipients, uris);
        assertEq(clone.nextTokenId(), 3);

        vm.prank(OPERATOR_MINTER);
        clone.mint(ALICE, "d");
        assertEq(clone.nextTokenId(), 4);
    }

    // ──────────────────────────────────────────────
    // Bytecode permanence (§7.2 row 15, §8.2)
    // ──────────────────────────────────────────────

    function test_implementation_runtimeCode_containsNoSelfdestruct() public view {
        // Walk EVM opcodes, skipping PUSH1..PUSH32 immediates (where 0xff can
        // legitimately appear as constant data). Any 0xff byte found at an
        // opcode position is a SELFDESTRUCT and would let the implementation be
        // wiped — see §7.2 row 15. `bytecode_hash = "none"` in foundry.toml
        // strips the metadata trailer that would otherwise produce false
        // positives at the end of runtime code.
        bytes memory code = address(impl).code;
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xff, "SELFDESTRUCT opcode at runtime position");
            if (op >= 0x60 && op <= 0x7f) {
                // PUSH1..PUSH32: skip (op - 0x5f) immediate bytes.
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
