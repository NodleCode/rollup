// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";

/// @notice Is PayBeneficiary actually binding once the deadline passes?
contract OnMissedBindingTest is FundraisingTestBase {
    function _payBeneficiary() internal returns (Fundraiser f, uint40 deadline) {
        FundraiserParams memory p = defaultParams();
        p.onMissed = OnMissed.PayBeneficiary;
        deadline = p.deadline;
        f = create(p);
        deposit(f, alice, 900e6); // below the 1000 goal
    }

    /// @dev After the deadline the policy says the beneficiary is owed the 900.
    ///      cancel() has no deadline gate, so the organizer can override it.
    function test_organizerCanCancelAfterDeadline_overridingPayBeneficiary() public {
        (Fundraiser f, uint40 deadline) = _payBeneficiary();
        vm.warp(uint256(deadline) + 1);

        vm.prank(organizer);
        f.cancel();

        assertEq(uint8(f.status()), uint8(Status.Refunding), "policy overridden");
        vm.prank(alice);
        f.refund();
        assertEq(balanceOf(f, alice), FUNDED);
        assertEq(balanceOf(f, beneficiary), FUNDED, "beneficiary got nothing");
    }

    /// @dev And a contributor can walk before anyone finalizes.
    function test_contributorCanUnpledgeAfterDeadline_shrinkingThePayout() public {
        (Fundraiser f, uint40 deadline) = _payBeneficiary();
        vm.warp(uint256(deadline) + 1);

        vm.prank(alice);
        f.unpledge(900e6);
        assertEq(f.raised(), 0);

        f.finalize();
        assertEq(uint8(f.status()), uint8(Status.Succeeded));
        vm.prank(beneficiary);
        f.withdraw();
        assertEq(balanceOf(f, beneficiary), FUNDED, "beneficiary paid nothing");
    }

    /// @dev Finalizing promptly is what makes the policy stick.
    function test_finalizingAtTheDeadlineMakesItBinding() public {
        (Fundraiser f, uint40 deadline) = _payBeneficiary();
        vm.warp(deadline);
        f.finalize();

        vm.prank(organizer);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Succeeded));
        f.cancel();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFundraiser.InvalidState.selector, Status.Succeeded));
        f.unpledge(1);

        vm.prank(beneficiary);
        f.withdraw();
        assertEq(balanceOf(f, beneficiary), FUNDED + 900e6);
    }
}
