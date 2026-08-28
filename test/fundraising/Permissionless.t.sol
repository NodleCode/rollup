// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import "./FundraisingTestBase.sol";
import {PermitERC20} from "./mocks/PermitERC20.sol";

/// @notice A contract wallet, to prove nothing assumes an externally-owned account.
contract SmartWallet {
    function call(address target, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "SmartWallet: call failed");
        return ret;
    }
}

/// @notice The escrow asks nobody for permission. These are the consequences, including
///         the ones we accepted rather than prevented.
contract PermissionlessTest is FundraisingTestBase {
    function test_anyoneCanCreate_organizerIsWhoeverCalled() public {
        vm.prank(stranger);
        address f = factory.createFundraiser(defaultParams(), bytes32("whatever"));

        assertEq(Fundraiser(f).organizer(), stranger);
        assertTrue(factory.isFundraiser(f));
    }

    function test_nonMemberContributesAndRefundsLikeAnyoneElse() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);

        deposit(f, stranger, 400e6);
        assertEq(f.contributions(stranger), 400e6);

        vm.warp(p.deadline);
        f.finalize();
        vm.prank(stranger);
        f.refund();
        assertEq(balanceOf(f, stranger), FUNDED);
    }

    /// @dev `externalId` is a hint, not a claim. Two unrelated fundraises may carry the same
    ///      tag, which is why callers must resolve a fundraise from their own records.
    function test_externalIdIsNotUnique_andNotVerified() public {
        vm.prank(organizer);
        address real = factory.createFundraiser(defaultParams(), bytes32("external-1"));

        FundraiserParams memory impostorParams = defaultParams();
        impostorParams.beneficiary = stranger;
        vm.prank(stranger);
        address impostor = factory.createFundraiser(impostorParams, bytes32("external-1"));

        assertTrue(real != impostor);
        assertTrue(factory.isFundraiser(real) && factory.isFundraiser(impostor));
        assertEq(Fundraiser(impostor).beneficiary(), stranger);
    }

    /// @dev Accepted residual, documented rather than prevented: anyone can cover the
    ///      remaining gap, which closes every contributor's exit. The money still goes to
    ///      the beneficiary the contributors saw at creation.
    function test_strangerFundsTheGap_andClosesEveryExit() public {
        Fundraiser f = createDefault();
        deposit(f, alice, 900e6);
        assertTrue(f.canUnpledge());

        deposit(f, stranger, 100e6);

        assertFalse(f.canUnpledge());
        vm.prank(alice);
        vm.expectRevert(IFundraiser.GoalReached.selector);
        f.unpledge(1);

        f.finalize();
        vm.prank(beneficiary);
        f.withdraw();
        assertEq(balanceOf(f, beneficiary), FUNDED + GOAL);
    }

    /// @dev The sharpest form: an organizer who is also the beneficiary recovers their own
    ///      top-up, so forcing a partial raise to completion is close to free for them.
    function test_organizerIsBeneficiary_gapFundingIsNearlyFree() public {
        FundraiserParams memory p = defaultParams();
        p.beneficiary = organizer;
        Fundraiser f = create(p);

        deposit(f, alice, 900e6);
        uint256 organizerBefore = balanceOf(f, organizer);

        deposit(f, organizer, 100e6); // covers the gap out of their own pocket
        f.finalize();
        vm.prank(organizer);
        f.withdraw();

        // they got their 100 back plus alice's 900
        assertEq(balanceOf(f, organizer), organizerBefore + 900e6);
        assertEq(f.contributions(alice), 900e6);
    }

    function test_smartAccountCanContributeAndRefund() public {
        SmartWallet wallet = new SmartWallet();
        token.mint(address(wallet), FUNDED);

        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);

        wallet.call(address(token), abi.encodeCall(IERC20Like.approve, (address(f), 500e6)));
        wallet.call(address(f), abi.encodeCall(IFundraiser.deposit, (500e6)));
        assertEq(f.contributions(address(wallet)), 500e6);

        vm.warp(p.deadline);
        f.finalize();
        wallet.call(address(f), abi.encodeCall(IFundraiser.refund, ()));
        assertEq(token.balanceOf(address(wallet)), FUNDED);
    }

    function test_depositWithPermit_singleTransaction() public {
        PermitERC20 prm = new PermitERC20();
        vm.prank(admin);
        factory.setTokenAllowed(address(prm), true);

        (address signer, uint256 pk) = makeAddrAndKey("permitSigner");
        prm.mint(signer, FUNDED);

        FundraiserParams memory p = defaultParams();
        p.token = address(prm);
        Fundraiser f = create(p);

        uint256 amount = 400e6;
        uint256 permitDeadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(f),
                amount,
                prm.nonces(signer),
                permitDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", prm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.prank(signer);
        f.depositWithPermit(amount, permitDeadline, v, r, s); // no separate approval

        assertEq(f.contributions(signer), amount);
    }

    /// @dev A permit consumed by someone else in the mempool must not fail the deposit.
    function test_depositWithPermit_survivesAFrontRunPermit() public {
        PermitERC20 prm = new PermitERC20();
        vm.prank(admin);
        factory.setTokenAllowed(address(prm), true);

        (address signer, uint256 pk) = makeAddrAndKey("permitSigner2");
        prm.mint(signer, FUNDED);

        FundraiserParams memory p = defaultParams();
        p.token = address(prm);
        Fundraiser f = create(p);

        uint256 amount = 400e6;
        uint256 permitDeadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(f),
                amount,
                prm.nonces(signer),
                permitDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", prm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // someone else submits the permit first, consuming the nonce
        vm.prank(stranger);
        prm.permit(signer, address(f), amount, permitDeadline, v, r, s);

        // the deposit still lands, because the allowance it needed now exists
        vm.prank(signer);
        f.depositWithPermit(amount, permitDeadline, v, r, s);
        assertEq(f.contributions(signer), amount);
    }

    /// @dev Nothing in the escrow assumes sponsored gas. Every state-changing call here is
    ///      an ordinary self-paying transaction with no paymaster in the picture.
    function test_everyPathWorksWithoutAnyPaymaster() public {
        FundraiserParams memory p = defaultParams();
        Fundraiser f = create(p);

        deposit(f, alice, 400e6);
        vm.prank(alice);
        f.unpledge(100e6);
        deposit(f, bob, 200e6);

        vm.warp(p.deadline);
        vm.prank(carol);
        f.finalize();

        vm.prank(alice);
        f.refund();
        vm.prank(carol);
        f.refundFor(bob);

        assertEq(balanceOf(f, alice), FUNDED);
        assertEq(balanceOf(f, bob), FUNDED);
        assertEq(balanceOf(f, address(f)), 0);
    }
}
