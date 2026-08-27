// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {Fundraiser} from "./Fundraiser.sol";
import {IFundraiserFactory} from "./interfaces/IFundraiserFactory.sol";
import {FundraiserParams, MAX_FUNDRAISE_DURATION, MAX_FEE_BPS_LIMIT} from "./interfaces/FundraisingTypes.sol";

/**
 * @title FundraiserFactory
 * @notice Deploys one `Fundraiser` contract per fundraise and holds what they share:
 *         which tokens may be collected, and the protocol fee.
 * @dev Immutable and not proxied. Changing the escrow's behavior means deploying a new
 *      factory, which by construction cannot touch anything already live.
 *
 *      Each fundraise is a full contract deployed with `new`, not a proxy or a clone.
 *      EIP-1167 clones do not work on zkSync Era at all, and a proxy measured more
 *      expensive there than deploying directly. See
 *      `src/fundraising/doc/spec/group-fundraising-design.md` section 6.
 *
 *      The admin's entire reach is the token allow-list and the fee parameters, both of
 *      which affect only future fundraises, plus the fee recipient read at withdrawal
 *      time. It cannot resolve, cancel, redirect or touch the funds of any fundraise.
 */
contract FundraiserFactory is IFundraiserFactory, AccessControl {
    /// @inheritdoc IFundraiserFactory
    uint16 public constant override MAX_FEE_BPS = MAX_FEE_BPS_LIMIT;

    /// @inheritdoc IFundraiserFactory
    uint40 public constant override MAX_DURATION = MAX_FUNDRAISE_DURATION;

    /// @inheritdoc IFundraiserFactory
    mapping(address => bool) public override isTokenAllowed;

    /// @inheritdoc IFundraiserFactory
    uint16 public override feeBps;

    /// @inheritdoc IFundraiserFactory
    address public override feeRecipient;

    /// @inheritdoc IFundraiserFactory
    mapping(address => bool) public override isFundraiser;

    /// @param admin Receives `DEFAULT_ADMIN_ROLE`. Expected to be a multisig.
    /// @param initialFeeBps Starting fee rate. Zero ships the capability switched off.
    /// @param initialFeeRecipient Where fees are sent. May be the zero address while the
    ///        rate is zero.
    /// @param initialTokens Tokens allowed at launch.
    /// @dev The allow-list is seeded here because the admin is expected to be a multisig
    ///      that a deploy script cannot act for.
    constructor(address admin, uint16 initialFeeBps, address initialFeeRecipient, address[] memory initialTokens) {
        if (admin == address(0)) revert ZeroAddress();
        _setFeeParams(initialFeeBps, initialFeeRecipient);

        for (uint256 i = 0; i < initialTokens.length; ++i) {
            address t = initialTokens[i];
            if (t == address(0)) revert ZeroAddress();
            isTokenAllowed[t] = true;
            emit TokenAllowed(t, true);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ──────────────────────────────────────────────
    // Creation
    // ──────────────────────────────────────────────

    /// @inheritdoc IFundraiserFactory
    /// @dev **No role gate, deliberately.** Anyone may deploy a fundraise; the contract is
    ///      group-agnostic and membership is a product-layer concern. The allow-list check
    ///      is the only validation that belongs here rather than in the escrow's own
    ///      constructor, because it is the only rule the escrow cannot know for itself.
    function createFundraiser(FundraiserParams calldata params, bytes32 groupId)
        external
        override
        returns (address fundraiser)
    {
        if (!isTokenAllowed[params.token]) revert TokenNotAllowed(params.token);

        // SECURITY INVARIANT: the `isFundraiser` write below lands AFTER the deploy. That
        // is reentrancy-safe ONLY because `Fundraiser`'s constructor makes no external
        // calls — it validates arguments and writes its own storage, nothing more. If that
        // ever changes, either reorder so the registry write precedes the deploy, or add a
        // reentrancy guard here.
        fundraiser = address(new Fundraiser(params, msg.sender, feeBps, address(this)));

        isFundraiser[fundraiser] = true;

        emit FundraiserCreated(
            fundraiser, msg.sender, params.token, groupId, params.goal, params.deadline, params.beneficiary
        );
    }

    // ──────────────────────────────────────────────
    // Administration
    // ──────────────────────────────────────────────

    /// @inheritdoc IFundraiserFactory
    /// @dev De-listing only stops *new* fundraises choosing this token. Live ones never
    ///      consult the allow-list again, so de-listing can never become a freeze switch
    ///      over deposits, withdrawals or refunds already in flight.
    function setTokenAllowed(address token, bool allowed) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        isTokenAllowed[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    /// @inheritdoc IFundraiserFactory
    function setFeeParams(uint16 newFeeBps, address newFeeRecipient) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setFeeParams(newFeeBps, newFeeRecipient);
    }

    /// @dev A rate change reaches only fundraises created afterward: each snapshots the
    ///      rate by value at creation, so nothing in flight can be skimmed. The recipient
    ///      is read live at withdrawal, which lets a lost collection key be rotated without
    ///      touching live fundraises and cannot change how much anyone receives.
    function _setFeeParams(uint16 newFeeBps, address newFeeRecipient) private {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_FEE_BPS);
        // A non-zero rate with nowhere to send it would silently collect nothing.
        if (newFeeBps != 0 && newFeeRecipient == address(0)) revert ZeroAddress();

        feeBps = newFeeBps;
        feeRecipient = newFeeRecipient;

        emit FeeParamsUpdated(newFeeBps, newFeeRecipient);
    }
}
