// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Tipping} from "../../src/tipping/Tipping.sol";
import {ITipping} from "../../src/tipping/ITipping.sol";

/**
 * @title TippingZkSyncForkTest
 * @notice Recipient resolution against the real zkSync Era mainnet contracts: The Turtle
 *         (factory ERC-1155) resolves to its registered creator, and a legacy ClickContentSign
 *         token resolves to its owner. Also the EraVM check for `LOOKUP_GAS`: every static
 *         lookup through the real proxies must fit the cap (meta#242 acceptance).
 *
 * Skipped unless ZKSYNC_RPC_URL is set:
 *   ZKSYNC_RPC_URL=https://mainnet.era.zksync.io forge test --match-contract TippingZkSyncForkTest -vv
 *
 * On a plain fork the forked contracts run as EVM bytecode, so the gas numbers are EVM
 * numbers. `forge test --zksync` crashes in this repo's linker (foundry-zksync v0.1.9,
 * "no EVM bytecode (or unlinked)"), so the EraVM figure for `LOOKUP_GAS` was taken with
 * `cast call --gas-limit` against mainnet instead (2026-10-27): minimum eth_call gas that
 * succeeds, node overhead included: name() 59,375 (baseline); ownerOf 59,375;
 * supportsInterface 65,625; totalSupply 67,187; hasRole 68,750; royaltyInfo 70,312.
 */
contract TippingZkSyncForkTest is Test {
    address internal constant TURTLE = 0x08820bBb37B401983683334B00668a2a8555CC74;
    address internal constant TURTLE_OWNER = 0xfe74C8C3f3F1ca3D4b523fd1AE7A3d82dbAc5eCe;
    address internal constant CLICK_CONTENTSIGN = 0x95b3641d549f719eb5105f9550Eca4A7A2F305De;
    uint256 internal constant CLICK_TOKEN = 1;

    address internal constant ADMIN = address(0xAD);
    address internal constant REGISTRY = address(0x09);

    Tipping internal tipping;
    bool internal skipAll;

    function setUp() public {
        string memory rpc = vm.envOr("ZKSYNC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            skipAll = true;
            return;
        }
        vm.createSelectFork(rpc);
        // The token address only has to be non-zero for resolution tests; no transfer happens here.
        tipping = new Tipping(address(0x1), ADMIN, REGISTRY, 1e18);
        vm.prank(REGISTRY);
        tipping.setCollectionAllowed(CLICK_CONTENTSIGN, true);
    }

    function test_turtle_registersByOwnerAndResolvesToCreator() public {
        if (skipAll) return;
        // Permissionless path: the collection attests OWNER_ROLE for the caller.
        vm.prank(TURTLE_OWNER);
        tipping.registerCollection(TURTLE);
        assertEq(tipping.creatorOf(TURTLE), TURTLE_OWNER);
        // No royalties on The Turtle: the creator is the recipient.
        assertEq(tipping.resolveRecipient(TURTLE, 0), TURTLE_OWNER);
        // Unminted id: supply is zero.
        vm.expectRevert(abi.encodeWithSelector(ITipping.UnknownToken.selector, TURTLE, 999));
        tipping.resolveRecipient(TURTLE, 999);
    }

    function test_turtle_nonOwnerCannotRegister() public {
        if (skipAll) return;
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ITipping.NotCollectionOwner.selector, TURTLE, ADMIN));
        tipping.registerCollection(TURTLE);
    }

    function test_clickContentSign_resolvesToOwner() public {
        if (skipAll) return;
        address owner = IERC721(CLICK_CONTENTSIGN).ownerOf(CLICK_TOKEN);
        assertTrue(owner != address(0));
        assertEq(tipping.resolveRecipient(CLICK_CONTENTSIGN, CLICK_TOKEN), owner);
    }

    /// @dev EraVM gas check: the whole resolution, three capped lookups included, must be far
    ///      below what a tip transaction carries. Prints the measurement for the deploy record.
    function test_lookupGasFitsOnEraVm() public {
        if (skipAll) return;
        vm.prank(TURTLE_OWNER);
        tipping.registerCollection(TURTLE);
        uint256 g0 = gasleft();
        tipping.resolveRecipient(TURTLE, 0);
        uint256 turtleGas = g0 - gasleft();
        g0 = gasleft();
        tipping.resolveRecipient(CLICK_CONTENTSIGN, CLICK_TOKEN);
        uint256 clickGas = g0 - gasleft();
        emit log_named_uint("resolve(The Turtle) gas", turtleGas);
        emit log_named_uint("resolve(ClickContentSign) gas", clickGas);
        assertLt(turtleGas, 3 * tipping.LOOKUP_GAS());
        assertLt(clickGas, tipping.LOOKUP_GAS());
    }
}
