// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ArcadeEscrow} from "../../src/arcade/ArcadeEscrow.sol";
import {MockERC20} from "../__helpers__/MockERC20.sol";

/// @notice Drives the escrow through random sequences of every public action.
/// @dev Calls are wrapped in try/catch: a revert is a legitimate outcome (paused, not ready,
///      over quota), and what matters is that the invariants hold after whatever succeeded.
contract ArcadeEscrowHandler is Test {
    ArcadeEscrow public escrow;
    MockERC20 public token;
    address public admin;
    address public oracle;
    address[] public actors;

    // ghosts
    uint256 public totalCharged;
    uint256 public totalFeesWithdrawn;
    uint256 public refNonce;
    bool public sawWithdrawBlockedByPause;

    constructor(ArcadeEscrow escrow_, MockERC20 token_, address admin_, address oracle_, address[] memory actors_) {
        escrow = escrow_;
        token = token_;
        admin = admin_;
        oracle = oracle_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 actorSeed, uint96 amount) external {
        address a = _actor(actorSeed);
        uint256 value = bound(uint256(amount), 1, 1_000 ether);
        token.mint(a, value);
        vm.startPrank(a);
        token.approve(address(escrow), value);
        try escrow.deposit(value) {} catch {}
        vm.stopPrank();
    }

    function depositFor(uint256 fromSeed, uint256 toSeed, uint96 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 value = bound(uint256(amount), 1, 1_000 ether);
        token.mint(from, value);
        vm.startPrank(from);
        token.approve(address(escrow), value);
        try escrow.depositFor(to, value) {} catch {}
        vm.stopPrank();
    }

    function requestWithdraw(uint256 actorSeed, uint96 amount) external {
        address a = _actor(actorSeed);
        uint256 value = bound(uint256(amount), 1, 2_000 ether);
        vm.prank(a);
        try escrow.requestWithdraw(value) {} catch {}
    }

    function cancelWithdraw(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        try escrow.cancelWithdraw() {} catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        (uint128 pending, uint64 readyAt) = escrow.withdrawals(a);
        vm.prank(a);
        try escrow.withdraw() {}
        catch {
            if (pending != 0 && block.timestamp >= readyAt && escrow.paused()) sawWithdrawBlockedByPause = true;
        }
    }

    function charge(uint256 actorSeed, uint96 amount) external {
        address a = _actor(actorSeed);
        uint256 value = bound(uint256(amount), 1, 200 ether);
        bytes32 ref = bytes32(++refNonce);
        vm.prank(oracle);
        try escrow.charge(a, value, ref) {
            totalCharged += value;
        } catch {}
    }

    function withdrawFees(uint96 amount) external {
        uint256 value = bound(uint256(amount), 0, escrow.feesAccrued());
        vm.prank(admin);
        try escrow.withdrawFees(admin, value) {
            totalFeesWithdrawn += value;
        } catch {}
    }

    function togglePause() external {
        vm.startPrank(admin);
        if (escrow.paused()) escrow.unpause();
        else escrow.pause();
        vm.stopPrank();
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 0, 2 days));
    }
}

contract ArcadeEscrowInvariantTest is Test {
    ArcadeEscrow escrow;
    MockERC20 token;
    ArcadeEscrowHandler handler;

    address admin = makeAddr("admin");
    address oracle = makeAddr("oracle");

    function setUp() public {
        token = new MockERC20("Nodle", "NODL", 18);
        escrow = new ArcadeEscrow(address(token), oracle, admin, 2_000 ether, 1 days, 1 ether, 100 ether, 1 hours);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("a0");
        actors[1] = makeAddr("a1");
        actors[2] = makeAddr("a2");
        actors[3] = makeAddr("a3");

        handler = new ArcadeEscrowHandler(escrow, token, admin, oracle, actors);
        targetContract(address(handler));
    }

    function _sumBalances() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            sum += escrow.balanceOf(handler.actors(i));
        }
    }

    /// @dev The admin can never reach users' balances: the escrow is always solvent.
    function invariant_solvent() public view {
        assertGe(token.balanceOf(address(escrow)), _sumBalances() + escrow.feesAccrued());
    }

    /// @dev With a plain ERC-20 and no stray transfers, solvency is exact.
    function invariant_accountingIsExact() public view {
        assertEq(token.balanceOf(address(escrow)), _sumBalances() + escrow.feesAccrued());
    }

    function invariant_feesTrackCharges() public view {
        assertEq(escrow.feesAccrued(), handler.totalCharged() - handler.totalFeesWithdrawn());
    }

    function invariant_quotaNeverExceeded() public view {
        assertLe(escrow.claimed(), escrow.quota());
    }

    function invariant_pauseNeverBlocksWithdraw() public view {
        assertFalse(handler.sawWithdrawBlockedByPause());
    }
}
