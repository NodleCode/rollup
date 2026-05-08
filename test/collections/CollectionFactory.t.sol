// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {CollectionFactory} from "../../src/collections/CollectionFactory.sol";
import {ICollectionFactory} from "../../src/collections/interfaces/ICollectionFactory.sol";
import {UserCollection721} from "../../src/collections/UserCollection721.sol";
import {UserCollection1155} from "../../src/collections/UserCollection1155.sol";
import {IUserCollection721} from "../../src/collections/interfaces/IUserCollection721.sol";
import {IUserCollection1155} from "../../src/collections/interfaces/IUserCollection1155.sol";
import {Standard, CreateParams721, CreateParams1155} from "../../src/collections/interfaces/CollectionTypes.sol";

import {CollectionFactoryV2Mock} from "./mocks/CollectionFactoryV2Mock.sol";
import {NonUUPSImplementationMock} from "./mocks/NonUUPSImplementationMock.sol";

contract CollectionFactoryTest is Test {
    CollectionFactory internal factory;
    UserCollection721 internal impl721;
    UserCollection1155 internal impl1155;

    address internal constant ADMIN = address(0xAD);
    address internal constant OPERATOR = address(0x09);
    address internal constant CREATOR = address(0xCAFE);
    address internal constant STRANGER = address(0xDEAD);
    address internal constant ALICE = address(0xA1);

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    event CollectionCreated(
        address indexed creator, address indexed collection, Standard standard, bytes32 indexed externalId
    );
    event ImplementationUpdated(Standard standard, address newImpl);
    event Upgraded(address indexed implementation);
    event Initialized(uint64 version);

    function setUp() public {
        impl721 = new UserCollection721();
        impl1155 = new UserCollection1155();

        CollectionFactory logic = new CollectionFactory();
        bytes memory init = abi.encodeCall(
            CollectionFactory.initialize, (ADMIN, OPERATOR, address(impl721), address(impl1155))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(logic), init);
        factory = CollectionFactory(address(proxy));
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _params721(address owner) internal pure returns (CreateParams721 memory) {
        return CreateParams721({
            owner: owner,
            name: "C",
            symbol: "C",
            baseURI: "ipfs://b/",
            contractURI: "ipfs://c.json",
            royaltyRecipient: owner,
            royaltyBps: 500,
            additionalMinters: new address[](0)
        });
    }

    function _params1155(address owner) internal pure returns (CreateParams1155 memory) {
        return CreateParams1155({
            owner: owner,
            uri: "ipfs://1155/{id}.json",
            contractURI: "ipfs://c.json",
            royaltyRecipient: owner,
            royaltyBps: 500,
            additionalMinters: new address[](0)
        });
    }

    // ──────────────────────────────────────────────
    // Initialization
    // ──────────────────────────────────────────────

    function test_initialize_grantsRolesAndSetsImplementations() public view {
        assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE, ADMIN));
        assertTrue(factory.hasRole(OPERATOR_ROLE, OPERATOR));
        assertEq(factory.erc721Implementation(), address(impl721));
        assertEq(factory.erc1155Implementation(), address(impl1155));
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(ADMIN, OPERATOR, address(impl721), address(impl1155));
    }

    function test_initialize_revertsOnZeroAddresses() public {
        CollectionFactory logic = new CollectionFactory();
        bytes memory bad = abi.encodeCall(
            CollectionFactory.initialize, (address(0), OPERATOR, address(impl721), address(impl1155))
        );
        vm.expectRevert();
        new ERC1967Proxy(address(logic), bad);
    }

    function test_initialize_revertsOnNonContractImpl() public {
        CollectionFactory logic = new CollectionFactory();
        bytes memory bad = abi.encodeCall(
            CollectionFactory.initialize, (ADMIN, OPERATOR, address(0xBEEF), address(impl1155))
        );
        vm.expectRevert();
        new ERC1967Proxy(address(logic), bad);
    }

    // ──────────────────────────────────────────────
    // Creation
    // ──────────────────────────────────────────────

    function test_createCollection721_atomicAndEmits() public {
        bytes32 externalId = keccak256("order-1");

        // Order: Upgraded(impl) → Initialized(1) → ... role grants ... → CollectionCreated
        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(impl721));

        vm.expectEmit(false, false, false, true);
        emit Initialized(1);

        // CollectionCreated indexed topics: (creator, collection, externalId).
        // We don't know the collection address up front, so leave its topic unchecked.
        vm.expectEmit(true, false, true, true);
        emit CollectionCreated(CREATOR, address(0), Standard.ERC721, externalId);

        vm.prank(OPERATOR);
        address collection = factory.createCollection721(_params721(CREATOR), externalId);

        assertEq(factory.collectionByExternalId(externalId), collection);
        UserCollection721 c = UserCollection721(collection);
        assertEq(c.name(), "C");
        assertEq(c.contractURI(), "ipfs://c.json");
        assertTrue(c.hasRole(keccak256("OWNER_ROLE"), CREATOR));
        // Operator auto-grant invariant — see §2.3.
        assertTrue(c.hasRole(MINTER_ROLE, OPERATOR));
    }

    function test_createCollection721_addressMatchesCreate2Derivation() public {
        bytes32 externalId = keccak256("derivation-test-721");
        CreateParams721 memory p = _params721(CREATOR);

        bytes memory initData = abi.encodeCall(
            IUserCollection721.initialize,
            (p, OPERATOR)
        );

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(address(impl721), initData)
            )
        );

        address predicted = Create2.computeAddress(
            externalId,
            initCodeHash,
            address(factory)
        );

        vm.prank(OPERATOR);
        address actual = factory.createCollection721(p, externalId);

        assertEq(actual, predicted, "deployed address must match CREATE2 derivation");
    }

    function test_createCollection1155_addressMatchesCreate2Derivation() public {
        bytes32 externalId = keccak256("derivation-test-1155");
        CreateParams1155 memory p = _params1155(CREATOR);

        bytes memory initData = abi.encodeCall(
            IUserCollection1155.initialize,
            (p, OPERATOR)
        );

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(address(impl1155), initData)
            )
        );

        address predicted = Create2.computeAddress(
            externalId,
            initCodeHash,
            address(factory)
        );

        vm.prank(OPERATOR);
        address actual = factory.createCollection1155(p, externalId);

        assertEq(actual, predicted, "deployed 1155 address must match CREATE2 derivation");
    }

    function test_createCollection1155_atomicAndEmits() public {
        bytes32 externalId = keccak256("order-1155");

        // Order: Upgraded(impl) → Initialized(1) → ... role grants ... → CollectionCreated
        vm.expectEmit(true, false, false, false);
        emit Upgraded(address(impl1155));

        vm.expectEmit(false, false, false, true);
        emit Initialized(1);

        // CollectionCreated indexed topics: (creator, collection, externalId).
        // We don't know the collection address up front, so leave its topic unchecked.
        vm.expectEmit(true, false, true, true);
        emit CollectionCreated(CREATOR, address(0), Standard.ERC1155, externalId);

        vm.prank(OPERATOR);
        address collection = factory.createCollection1155(_params1155(CREATOR), externalId);

        assertEq(factory.collectionByExternalId(externalId), collection);
        UserCollection1155 c = UserCollection1155(collection);
        assertTrue(c.hasRole(keccak256("OWNER_ROLE"), CREATOR));
        assertTrue(c.hasRole(MINTER_ROLE, OPERATOR));
    }

    function test_createCollection_onlyOperator() public {
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, OPERATOR_ROLE)
        );
        factory.createCollection721(_params721(CREATOR), keccak256("x"));
    }

    function test_createCollection_revertsZeroExternalId() public {
        vm.prank(OPERATOR);
        vm.expectRevert(ICollectionFactory.InvalidExternalId.selector);
        factory.createCollection721(_params721(CREATOR), bytes32(0));
    }

    function test_createCollection_revertsReusedExternalId() public {
        bytes32 externalId = keccak256("dup");
        vm.prank(OPERATOR);
        factory.createCollection721(_params721(CREATOR), externalId);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(ICollectionFactory.ExternalIdAlreadyUsed.selector, externalId));
        factory.createCollection721(_params721(CREATOR), externalId);
    }

    function test_createCollection_operatorAutoGrantWithEmptyAdditionalMinters() public {
        bytes32 externalId = keccak256("empty-minters");
        vm.prank(OPERATOR);
        address collection = factory.createCollection721(_params721(CREATOR), externalId);
        // additionalMinters is empty — operator must still be a minter via auto-grant.
        assertTrue(UserCollection721(collection).hasRole(MINTER_ROLE, OPERATOR));
    }

    function test_createCollection721_canMintImmediatelyInSameTx() public {
        bytes32 externalId = keccak256("immediate-mint-721");

        vm.startPrank(OPERATOR);
        address collection = factory.createCollection721(_params721(CREATOR), externalId);
        // Operator was auto-granted MINTER_ROLE during constructor delegatecall —
        // can mint without any extra setup transactions.
        uint256 tokenId = UserCollection721(collection).mint(ALICE, "ipfs://token-0.json");
        vm.stopPrank();

        assertEq(UserCollection721(collection).ownerOf(tokenId), ALICE);
    }

    // ──────────────────────────────────────────────
    // setImplementation*
    // ──────────────────────────────────────────────

    function test_setImplementation_onlyAdmin() public {
        UserCollection721 newImpl = new UserCollection721();
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, DEFAULT_ADMIN_ROLE)
        );
        factory.setImplementation721(address(newImpl));
    }

    function test_setImplementation_revertsZeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(ICollectionFactory.ZeroAddress.selector);
        factory.setImplementation721(address(0));
    }

    function test_setImplementation_revertsNonContract() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ICollectionFactory.NotAContract.selector, address(0xBEEF)));
        factory.setImplementation721(address(0xBEEF));
    }

    function test_setImplementation1155_updatesPointerAndEmits() public {
        UserCollection1155 newImpl = new UserCollection1155();
        vm.expectEmit(true, true, true, true);
        emit ImplementationUpdated(Standard.ERC1155, address(newImpl));
        vm.prank(ADMIN);
        factory.setImplementation1155(address(newImpl));
        assertEq(factory.erc1155Implementation(), address(newImpl));
    }

    function test_setImplementation1155_revertsZeroAndNonContract() public {
        vm.prank(ADMIN);
        vm.expectRevert(ICollectionFactory.ZeroAddress.selector);
        factory.setImplementation1155(address(0));

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ICollectionFactory.NotAContract.selector, address(0xBEEF)));
        factory.setImplementation1155(address(0xBEEF));
    }

    function test_setImplementation_affectsFutureCollectionsOnly() public {
        bytes32 firstId = keccak256("first");
        vm.prank(OPERATOR);
        address oldCollection = factory.createCollection721(_params721(CREATOR), firstId);
        bytes32 oldHash = oldCollection.codehash;

        UserCollection721 newImpl = new UserCollection721();
        vm.expectEmit(true, true, true, true);
        emit ImplementationUpdated(Standard.ERC721, address(newImpl));
        vm.prank(ADMIN);
        factory.setImplementation721(address(newImpl));

        bytes32 secondId = keccak256("second");
        vm.prank(OPERATOR);
        address newCollection = factory.createCollection721(_params721(CREATOR), secondId);

        // Old collection unchanged; new collection points at the new implementation
        // via its ERC1967 proxy. Verify by reading the factory's stored pointer
        // post-set.
        assertEq(oldCollection.codehash, oldHash);
        assertEq(factory.erc721Implementation(), address(newImpl));
        assertTrue(newCollection != oldCollection);
    }

    // ──────────────────────────────────────────────
    // UUPS upgrade — §8.1 four assertions
    // ──────────────────────────────────────────────

    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_uups_adminUpgradeChangesImplementationSlot() public {
        CollectionFactoryV2Mock v2Logic = new CollectionFactoryV2Mock();
        address pre = address(uint160(uint256(vm.load(address(factory), IMPL_SLOT))));
        assertTrue(pre != address(v2Logic));

        vm.prank(ADMIN);
        factory.upgradeToAndCall(address(v2Logic), "");

        address post = address(uint160(uint256(vm.load(address(factory), IMPL_SLOT))));
        assertEq(post, address(v2Logic));
    }

    function test_uups_revertsForOperatorOnly() public {
        CollectionFactoryV2Mock v2Logic = new CollectionFactoryV2Mock();
        // OPERATOR holds OPERATOR_ROLE but NOT DEFAULT_ADMIN_ROLE — must not escalate.
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, DEFAULT_ADMIN_ROLE)
        );
        factory.upgradeToAndCall(address(v2Logic), "");
    }

    function test_uups_revertsForFreshEoa() public {
        CollectionFactoryV2Mock v2Logic = new CollectionFactoryV2Mock();
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, DEFAULT_ADMIN_ROLE)
        );
        factory.upgradeToAndCall(address(v2Logic), "");
    }

    function test_uups_preservesStorageThroughUpgrade() public {
        // Seed pre-upgrade state.
        bytes32 externalId = keccak256("pre-upgrade");
        vm.prank(OPERATOR);
        address seededCollection = factory.createCollection721(_params721(CREATOR), externalId);

        CollectionFactoryV2Mock v2Logic = new CollectionFactoryV2Mock();
        vm.prank(ADMIN);
        factory.upgradeToAndCall(address(v2Logic), "");

        // Roles preserved.
        assertTrue(factory.hasRole(DEFAULT_ADMIN_ROLE, ADMIN));
        assertTrue(factory.hasRole(OPERATOR_ROLE, OPERATOR));
        // Implementation pointers preserved.
        assertEq(factory.erc721Implementation(), address(impl721));
        assertEq(factory.erc1155Implementation(), address(impl1155));
        // Pre-upgrade collection mapping preserved.
        assertEq(factory.collectionByExternalId(externalId), seededCollection);
        // V2-only function callable on the upgraded proxy — proves real delegation.
        assertEq(CollectionFactoryV2Mock(address(factory)).v2Sentinel(), 4242);
    }

    function test_uups_revertsOnNonUUPSImplementation() public {
        NonUUPSImplementationMock nonUups = new NonUUPSImplementationMock();
        vm.prank(ADMIN);
        // OZ wraps the failed proxiableUUID call in ERC1967InvalidImplementation.
        vm.expectRevert(
            abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(nonUups))
        );
        factory.upgradeToAndCall(address(nonUups), "");
    }
}
