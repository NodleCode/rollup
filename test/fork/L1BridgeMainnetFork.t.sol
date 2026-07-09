// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {L1Bridge} from "src/bridge/L1Bridge.sol";
import {IL1Bridge} from "src/bridge/interfaces/IL1Bridge.sol";
import {IWithdrawalMessage} from "src/bridge/interfaces/IWithdrawalMessage.sol";
import {L1Nodl} from "src/L1Nodl.sol";
import {IMailbox} from "lib/era-contracts/l1-contracts/contracts/state-transition/chain-interfaces/IMailbox.sol";

/// @dev Validates the Bridgehub migration against LIVE Ethereum mainnet state (no mocks).
///
/// Skipped unless MAINNET_RPC_URL is set:
///   MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract L1BridgeMainnetForkTest
///
/// Proves, against the real deployed zkSync contracts:
///  - deposits route through the real Bridgehub and enqueue a real priority op on the Era Diamond
///  - deposits keep working when the deprecated Mailbox entrypoint is disabled (simulated
///    mid-September 2026 cutoff, https://github.com/zkSync-Community-Hub/zksync-developers/discussions/1147)
///  - base-cost quotes from the Bridgehub match the legacy Mailbox quotes exactly
///  - the proof path verifies a REAL historical withdrawal proof (current proof format), and the
///    LEGACY_BRIDGE guard blocks re-minting withdrawals the live bridge already paid out
contract L1BridgeMainnetForkTest is Test {
    // Live mainnet addresses
    address internal constant BRIDGEHUB = 0x303a465B659cBB0ab36eE643eA362c509EEb5213;
    address internal constant ERA_DIAMOND = 0x32400084C286CF3E17e7B677ea9583e60a000324;
    address internal constant NODL_L1 = 0x6dd0E17ec6fE56c5f58a0Fe2Bb813B9b5cc25990;
    address internal constant L2_BRIDGE = 0x2c1B65dA72d5Cf19b41dE6eDcCFB7DD83d1B529E;
    address internal constant OLD_BRIDGE = 0x2D02b651Ea9630351719c8c55210e042e940d69a;
    address internal constant NODL_ADMIN_SAFE = 0x55f5E48A1d30d67ac13751b523Ca1b3cB5838AD8;
    uint256 internal constant ERA_CHAIN_ID = 324;

    // Real historical withdrawal, already finalized (paid out) by OLD_BRIDGE:
    // L2 tx 0x494c1b7becf09814e34a02403fb7a1bbe0f0de70e861de907ea3e4a70007efe7
    address internal constant W_RECEIVER = 0x2E7F3926Ae74FDCDcAde2c2AB50990C5daFD42bD;
    uint256 internal constant W_AMOUNT = 100 ether;
    uint256 internal constant W_BATCH = 503366;
    uint256 internal constant W_INDEX = 17;
    uint16 internal constant W_TX_IN_BATCH = 1025;

    address internal constant USER = address(0xBEEF01);

    bool internal skipAll;
    L1Bridge internal newBridge;
    L1Nodl internal nodl;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            skipAll = true;
            return;
        }
        vm.createSelectFork(rpc);

        nodl = L1Nodl(NODL_L1);
        newBridge = new L1Bridge(
            NODL_ADMIN_SAFE, ERA_DIAMOND, BRIDGEHUB, ERA_CHAIN_ID, NODL_L1, L2_BRIDGE, OLD_BRIDGE
        );

        // Mirror the deploy script: grant MINTER_ROLE to the new bridge (and to this test for funding USER)
        bytes32 minterRole = keccak256("MINTER_ROLE");
        vm.startPrank(NODL_ADMIN_SAFE);
        nodl.grantRole(minterRole, address(newBridge));
        nodl.grantRole(minterRole, address(this));
        vm.stopPrank();

        nodl.mint(USER, 1_000 ether);
        vm.deal(USER, 10 ether);
    }

    function test_Fork_QuoteMatchesLegacyMailbox() public {
        vm.skip(skipAll);
        uint256 viaBridge = newBridge.quoteL2BaseCostAtGasPrice(30 gwei, 750_000, 800);
        uint256 viaLegacyMailbox = IMailbox(ERA_DIAMOND).l2TransactionBaseCost(30 gwei, 750_000, 800);
        assertGt(viaBridge, 0, "quote is non-zero");
        assertEq(viaBridge, viaLegacyMailbox, "bridgehub quote == legacy mailbox quote");
    }

    function test_Fork_DepositViaRealBridgehub_EnqueuesPriorityOp() public {
        vm.skip(skipAll);
        uint256 fee = newBridge.quoteL2BaseCostAtGasPrice(100 gwei, 750_000, 800);

        vm.recordLogs();
        vm.startPrank(USER);
        nodl.approve(address(newBridge), 100 ether);
        bytes32 txHash = newBridge.deposit{value: fee}(USER, 100 ether, 750_000, 800, USER);
        vm.stopPrank();

        assertTrue(txHash != bytes32(0), "canonical L2 tx hash returned");
        assertEq(newBridge.depositAmount(USER, txHash), 100 ether, "deposit recorded");
        assertEq(nodl.balanceOf(USER), 900 ether, "NODL burned on L1");

        // The real Bridgehub must have routed the request into the Era diamond (NewPriorityRequest)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool diamondEmitted = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == ERA_DIAMOND) diamondEmitted = true;
        }
        assertTrue(diamondEmitted, "priority op enqueued on the Era diamond");
    }

    /// @dev Simulates the cutoff: the deprecated Mailbox entrypoint reverts. The old bridge's
    ///      deposit must break, the new bridge's must keep working — the Bridgehub reaches the
    ///      diamond through bridgehubRequestL2Transaction, which is not deprecated.
    function test_Fork_DepositSurvivesMailboxCutoff() public {
        vm.skip(skipAll);
        vm.mockCallRevert(
            ERA_DIAMOND, abi.encodeWithSelector(IMailbox.requestL2Transaction.selector), "MAILBOX_DEPRECATED"
        );

        uint256 fee = newBridge.quoteL2BaseCostAtGasPrice(100 gwei, 750_000, 800);

        // Old (live) bridge: deposit path dies with the cutoff
        vm.startPrank(USER);
        nodl.approve(OLD_BRIDGE, 100 ether);
        vm.expectRevert();
        IL1Bridge(OLD_BRIDGE).deposit{value: fee}(USER, 100 ether, 750_000, 800, USER);
        vm.stopPrank();

        // New bridge: unaffected
        vm.startPrank(USER);
        nodl.approve(address(newBridge), 100 ether);
        bytes32 txHash = newBridge.deposit{value: fee}(USER, 100 ether, 750_000, 800, USER);
        vm.stopPrank();
        assertTrue(txHash != bytes32(0), "new bridge deposit still works post-cutoff");
    }

    /// @dev The LEGACY_BRIDGE guard must reject a real withdrawal the live bridge already paid out,
    ///      even though its inclusion proof still verifies on the Diamond.
    function test_Fork_LegacyGuard_BlocksAlreadyPaidWithdrawal() public {
        vm.skip(skipAll);
        assertTrue(
            IL1Bridge(OLD_BRIDGE).isWithdrawalFinalized(W_BATCH, W_INDEX), "paid out by the live bridge"
        );

        bytes memory message = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, W_RECEIVER, W_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(L1Bridge.WithdrawalFinalizedOnLegacyBridge.selector));
        newBridge.finalizeWithdrawal(W_BATCH, W_INDEX, W_TX_IN_BATCH, message, _proof());
    }

    /// @dev Control test for the guard AND end-to-end validation of the untouched proof path:
    ///      without LEGACY_BRIDGE, the same real proof verifies through a fresh deployment and
    ///      re-mints an already-paid withdrawal. This is precisely why the guard exists.
    function test_Fork_ProofPathWorks_UnguardedDeploymentWouldDoubleMint() public {
        vm.skip(skipAll);
        L1Bridge unguarded = new L1Bridge(
            NODL_ADMIN_SAFE, ERA_DIAMOND, BRIDGEHUB, ERA_CHAIN_ID, NODL_L1, L2_BRIDGE, address(0)
        );
        vm.prank(NODL_ADMIN_SAFE);
        nodl.grantRole(keccak256("MINTER_ROLE"), address(unguarded));

        bytes memory message = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, W_RECEIVER, W_AMOUNT);
        uint256 balBefore = nodl.balanceOf(W_RECEIVER);

        unguarded.finalizeWithdrawal(W_BATCH, W_INDEX, W_TX_IN_BATCH, message, _proof());

        assertEq(nodl.balanceOf(W_RECEIVER), balBefore + W_AMOUNT, "proof verified; double mint without the guard");
    }

    /// @dev Real proof from zks_getL2ToL1LogProof for L2 tx
    ///      0x494c1b7becf09814e34a02403fb7a1bbe0f0de70e861de907ea3e4a70007efe7.
    function _proof() internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](34);
        proof[0] = bytes32(0x010f0c0000000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x0ca695adb6cd2557b399809493c32571f395d3235ebae0bfe26e8c858c540de2);
        proof[2] = bytes32(0x7506569fac3e4875cf4e85b7116ca1e5d9440c9c4a846e46be19bf60410784dd);
        proof[3] = bytes32(0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111);
        proof[4] = bytes32(0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa);
        proof[5] = bytes32(0x4b1e283abf89847c62fc462cee2cd2d754cbf6ffe234a58c99e70ce33b6bbf2c);
        proof[6] = bytes32(0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272);
        proof[7] = bytes32(0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d);
        proof[8] = bytes32(0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c);
        proof[9] = bytes32(0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db);
        proof[10] = bytes32(0x124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470f);
        proof[11] = bytes32(0xc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13f);
        proof[12] = bytes32(0xfef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87);
        proof[13] = bytes32(0xa707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00b);
        proof[14] = bytes32(0xf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291);
        proof[15] = bytes32(0x61f9014dca2a42d5c84750183d1eab288395ea56c40dba2a3dcbb8419a4a76d1);
        proof[16] = bytes32(0x0000000000000000000000000000000000000000000000000000000000000839);
        proof[17] = bytes32(0xa423b3ae90fbb11aab909ff2adbb43b417b76c9ecf9b4e431aa1582aa33c9649);
        proof[18] = bytes32(0x875a044615bb3fdc626ea29e67ddba1698c88067c710777dea4175c83fa84e51);
        proof[19] = bytes32(0x266f52b16165e9e2253be106c3774931e09bc1aff98955a74814788fbaba6b7f);
        proof[20] = bytes32(0xf115f0c003632b9f11dd351ccc97fc14b269b3dfd4123c5da136895b7af3849a);
        proof[21] = bytes32(0x284f69435a049f0c8ea7b7b16c1ed4f1f4684b8a839e2d5393fbb9349238b7ce);
        proof[22] = bytes32(0x7f19b4cba4533f2091bd7a46fdaa06d537f64adec0dd10b51d290ecaac0b53fa);
        proof[23] = bytes32(0x1dfbe77401207dce60055614f80a946ccc2c4e679c08c608370362c6279ae2f1);
        proof[24] = bytes32(0xf3096113152fab0a26666e9cd9519b711bd0a7c01c2d4c2eebed9a03d0b4c1f1);
        proof[25] = bytes32(0x1b10d93c70611fb12dc351df7ce060c9bfcd2eb9d75d6cdb1af3bf3092f3f31d);
        proof[26] = bytes32(0x8df5379fefae4adff70d71fd9e0f53a86f81b3e3a07c326468505b7a09d7521f);
        proof[27] = bytes32(0xda185173bf3eb691ad5a68eaab1484df2d96b8c5d29f75d5f65ac6b28ee39f5a);
        proof[28] = bytes32(0x09322b5b4ee02df10bd7f516b897ae97613bd520f40b57a3d1605ec8116388fb);
        proof[29] = bytes32(0x000000000000000000000000000005bc00000000000000000000000000000003);
        proof[30] = bytes32(0x0000000000000000000000000000000000000000000000000000000000002373);
        proof[31] = bytes32(0x0102000100000000000000000000000000000000000000000000000000000000);
        proof[32] = bytes32(0xe1a9e1f81a34b35c1f650e82d96be72f05aa6492807c180d1d93c8936674a7ed);
        proof[33] = bytes32(0x9761ab4b675ea36d6001c772483906a4b6337e84349493e01d9d269dc8deb55d);
    }
}
