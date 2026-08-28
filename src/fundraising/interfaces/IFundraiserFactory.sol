// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {FundraiserParams} from "./FundraisingTypes.sol";

/**
 * @title IFundraiserFactory
 * @notice Deploys one `IFundraiser` contract per fundraise and holds the settings shared
 *         across them: which tokens may be collected, and the protocol fee.
 * @dev Creation is **permissionless** — anyone may deploy a fundraise, and anyone may
 *      contribute to one. There is no membership or eligibility check on-chain.
 *
 *      Each fundraise is a full contract deployed with `new`, not a proxy or a clone.
 *      EIP-1167 clones do not work on zkSync Era at all, and a proxy measured more
 *      expensive than a direct deployment there — see
 *      `src/fundraising/doc/spec/fundraising-design.md` section 6.
 */
interface IFundraiserFactory {
    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    /// @notice Emitted when a new fundraise is deployed.
    /// @param fundraiser Address of the newly deployed escrow.
    /// @param organizer Whoever created it, and the only address that may cancel it.
    /// @param externalId An opaque tag supplied by the caller for off-chain reconciliation.
    /// @dev `externalId` is **a hint, not a claim**. Nothing verifies it, and anyone may tag a
    ///      fundraise with any value, including one already in use. Resolve a fundraise from
    ///      records written when it was created, never from this tag, or an unrelated
    ///      contract can be mistaken for a known one.
    event FundraiserCreated(
        address indexed fundraiser,
        address indexed organizer,
        address indexed token,
        bytes32 externalId,
        uint128 goal,
        uint40 deadline,
        address beneficiary
    );

    /// @notice Emitted when a token is added to or removed from the allow-list.
    /// @dev De-listing only prevents *new* fundraises choosing that token. It never blocks
    ///      deposits, withdrawals or refunds on live ones, which would make de-listing a
    ///      freeze switch.
    event TokenAllowed(address indexed token, bool allowed);

    /// @notice Emitted when the protocol fee rate or recipient changes.
    /// @dev A rate change applies only to fundraises created afterward. Live ones keep the
    ///      rate they were created with.
    event FeeParamsUpdated(uint16 feeBps, address feeRecipient);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when the chosen token is not on the allow-list.
    /// @dev The allow-list is what keeps rebasing and other unsupported tokens out of an
    ///      escrow whose accounting cannot survive them.
    error TokenNotAllowed(address token);

    /// @notice Thrown when a fee rate above `MAX_FEE_BPS` is configured.
    error FeeTooHigh(uint16 feeBps, uint16 maximum);

    // ──────────────────────────────────────────────
    // Creation
    // ──────────────────────────────────────────────

    /// @notice Deploy a new fundraise.
    /// @dev Callable by anyone. Checks the token allow-list and snapshots the current fee
    ///      rate into the new contract by value; all other validation happens in the
    ///      fundraise's own constructor, so it enforces its invariants regardless of who
    ///      deploys it.
    /// @param externalId Opaque off-chain tag, emitted and never stored. See `FundraiserCreated`.
    /// @return fundraiser Address of the newly deployed escrow.
    function createFundraiser(FundraiserParams calldata params, bytes32 externalId)
        external
        returns (address fundraiser);

    // ──────────────────────────────────────────────
    // Administration
    // ──────────────────────────────────────────────

    /// @notice Add or remove a token from the allow-list for future fundraises.
    function setTokenAllowed(address token, bool allowed) external;

    /// @notice Set the protocol fee rate and recipient for future fundraises.
    /// @dev The rate is snapshotted per fundraise at creation, so this cannot skim anything
    ///      already in flight. The recipient is read at withdrawal time, so a lost
    ///      collection key can be rotated without touching live fundraises.
    function setFeeParams(uint16 newFeeBps, address newFeeRecipient) external;

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    /// @notice Hard ceiling on the protocol fee, in basis points.
    /// @dev A constant, so even a compromised admin cannot set a confiscatory fee.
    function MAX_FEE_BPS() external view returns (uint16);

    /// @notice Longest permitted time from creation to deadline.
    function MAX_DURATION() external view returns (uint40);

    function isTokenAllowed(address token) external view returns (bool);
    function feeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);

    /// @notice Whether an address was deployed by this factory.
    /// @dev Lets indexers and refund sweepers verify provenance on-chain instead of trusting
    ///      an address they were handed.
    function isFundraiser(address account) external view returns (bool);
}
