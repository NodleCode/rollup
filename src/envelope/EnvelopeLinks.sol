// SPDX-License-Identifier: GPL-3.0-or-later
// Originally derived from peanutprotocol/peanut-contracts (V4.4).
// Full GPL v3 text: src/envelope/LICENSE-GPL
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract EnvelopeLinks is IERC721Receiver, IERC1155Receiver, ReentrancyGuard, Ownable2Step, EIP712 {
    using SafeERC20 for IERC20;

    // ── Custom Errors ────────────────────────────────────────────────────────────

    error InvalidContractType();
    error WrongEthAmount();
    error Erc721AmountMustBeOne();
    error LinkIndexOutOfBounds();
    error LinkAlreadyRedeemed();
    error RequiresMfaAuthorization();
    error MfaNotRequired();
    error WrongMfaSignature();
    error WrongSignature();
    error WrongRecipient();
    error NotTheRecipient();
    error NotTheCreator();
    error TooEarlyToReclaim();
    error EthTransferFailed();
    error DirectTransfersNotAllowed();
    error NoFeesToWithdraw();
    error MfaSignatureExpired();
    error FeeAuthorizationExpired();
    error WrongFeeAuthorizationSignature();
    error FeeTokenNotConfigured();
    error ParametersLengthMismatch();
    error InvalidTotalEtherSent();
    error EthNotAcceptedForNonEthLink();
    error Erc721BatchNotSupported();
    error UnsupportedRaffleContractType();
    error InsufficientTokensReceived();
    error ZeroRecipientAddress();
    error LinkNotRecipientBound();
    error FeeAuthorizationAlreadyUsed();
    error ZeroMfaAuthorizer();
    error ZeroClaimKey();
    error UnevenBatchAmount();
    error FeeTokenTransferAmountMismatch();

    // ── Data Structures ──────────────────────────────────────────────────────────

    struct LinkStatus {
        address claimKey; // address derived from the link claim private key
        bool redeemed; // has this link been redeemed
        bool requiresMFA; // is additional auth (MFA) required?
        bool gaslessSponsored; // can the paymaster sponsor this link without a prepaid gasless fee?
        uint40 timestamp; // timestamp of the link creation
    }

    struct LinkAsset {
        address tokenAddress; // address of the asset being sent. 0x0 for eth
        uint8 contractType; // 0 for eth, 1 for erc20, 2 for erc721, 3 for erc1155
        uint256 amount; // amount of the asset being sent
        uint256 tokenId; // id of the token being sent (if erc721 or erc1155)
    }

    struct LinkParties {
        address creator; // address of the sender or delegated creator
        address recipient; // unless it's 0x00, only this address can claim the link
        uint40 reclaimableAfter; // for address-bound links, the sender can reclaim only after this timestamp
    }

    struct LinkFees {
        uint256 serviceFee; // backend-authorized service fee collected at link creation
        uint256 gaslessFee; // prepaid gas sponsorship fee collected at link creation
    }

    struct Link {
        LinkStatus status;
        LinkAsset asset;
        LinkParties parties;
        LinkFees fees;
    } // 8 storage slots (32 byte each)

    /// @notice Full link intent covered by a backend fee authorization.
    struct LinkRequest {
        address tokenAddress;
        uint8 contractType;
        uint256 amount;
        uint256 tokenId;
        address claimKey;
        address onBehalfOf;
        bool withMFA;
        address recipient;
        uint40 reclaimableAfter;
    }

    /// @notice Backend-signed fee bundle collected when a link is created.
    /// @dev deadline == 0 means no expiry. Non-zero fees or sponsored gasless eligibility require
    ///      `signature` from `mfaAuthorizer`. Zero-fee authorizations with a non-empty signature are verified too.
    struct FeeAuthorization {
        uint256 serviceFee;
        uint256 gaslessFee;
        bool gaslessSponsored;
        uint256 deadline;
        bytes signature;
    }

    // ── EIP-712 Typehashes ───────────────────────────────────────────────────────

    bytes32 public constant CLAIM_TYPEHASH = keccak256("Claim(uint256 index,address recipient,bytes32 mode)");

    bytes32 public constant MFA_APPROVAL_TYPEHASH =
        keccak256("MfaApproval(uint256 index,address recipient,uint256 deadline)");

    bytes32 public constant FEE_AUTHORIZATION_TYPEHASH = keccak256(
        "FeeAuthorization(address feePayer,address tokenAddress,uint8 contractType,uint256 amount,uint256 tokenId,address claimKey,address onBehalfOf,bool withMFA,address recipient,uint40 reclaimableAfter,uint256 serviceFee,uint256 gaslessFee,bool gaslessSponsored,uint256 deadline)"
    );

    bytes32 public constant OPEN_CLAIM_MODE = 0x0000000000000000000000000000000000000000000000000000000000000000;
    bytes32 public constant BOUND_CLAIM_MODE = 0x2bb5bef2b248d3edba501ad918c3ab524cce2aea54d4c914414e1c4401dc4ff4; // keccak256("only recipient")

    /// @notice Address authorized to issue MFA signatures gating claimWithMFA calls and fee authorizations.
    /// @dev Rotatable by owner. Setting to address(0) is rejected — MFA and fee-authorized creation are
    ///      always-on for production. Use rotation to disable a compromised key by replacing it.
    address public mfaAuthorizer;

    Link[] internal links; // array of links

    /// @notice ERC-20 token used for Envelope service and gasless sponsorship fees (for example NODL).
    IERC20 public immutable feeToken;

    /// @notice Accumulated fees in feeToken from createLinkWithFees/createCustomLinksWithFees.
    /// @dev ETH fees are not supported; the protocol intentionally collects fees only in feeToken.
    uint256 public accumulatedFees;

    /// @notice Tracks consumed fee authorizations to prevent replay (keyed by the EIP-712 digest).
    mapping(bytes32 => bool) public usedFeeAuthorizations;

    // events
    event LinkCreated(uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _creator);
    event LinkRedeemed(
        uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _recipientAddress
    );
    event FeeCollected(uint256 indexed _index, address indexed tokenAddress, uint256 serviceFee, uint256 gaslessFee);
    event FeesWithdrawn(address indexed tokenAddress, uint256 amount);
    event MfaAuthorizerUpdated(address indexed oldAuthorizer, address indexed newAuthorizer);

    /// @param _mfaAuthorizer address authorized to sign backend fee and MFA approvals. Must be non-zero;
    ///        this single key gates both MFA-protected claims and fee authorizations.
    /// @param _owner initial owner of the contract (receives accumulated fees).
    /// @param _feeToken ERC-20 token used for fees; address(0) disables non-zero fee authorizations.
    constructor(address _mfaAuthorizer, address _owner, address _feeToken)
        Ownable(_owner)
        EIP712("EnvelopeLinks", "5")
    {
        if (_mfaAuthorizer == address(0)) revert ZeroMfaAuthorizer();
        mfaAuthorizer = _mfaAuthorizer;
        feeToken = IERC20(_feeToken);
    }

    /**
     * @notice supportsInterface function
     * @dev ERC165 interface detection
     */
    function supportsInterface(bytes4 _interfaceId) external pure override(IERC165) returns (bool) {
        return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC721Receiver).interfaceId
            || _interfaceId == type(IERC1155Receiver).interfaceId;
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Link Creation Functions
    // ══════════════════════════════════════════════════════════════════════════════

    function createLink(address _tokenAddress, uint8 _contractType, uint256 _amount, uint256 _tokenId, address claimKey)
        public
        payable
        nonReentrant
        returns (uint256)
    {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeLink(
            _tokenAddress, _contractType, _amount, _tokenId, claimKey, msg.sender, false, address(0), 0, 0, 0, false
        );
    }

    function createMFALink(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address claimKey
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeLink(
            _tokenAddress, _contractType, _amount, _tokenId, claimKey, msg.sender, true, address(0), 0, 0, 0, false
        );
    }

    function createMFALinkFor(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address claimKey,
        address _onBehalfOf
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeLink(
            _tokenAddress, _contractType, _amount, _tokenId, claimKey, _onBehalfOf, true, address(0), 0, 0, 0, false
        );
    }

    function createLinkFor(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address claimKey,
        address _onBehalfOf
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeLink(
            _tokenAddress, _contractType, _amount, _tokenId, claimKey, _onBehalfOf, false, address(0), 0, 0, 0, false
        );
    }

    /**
     * @notice The main function that supports all scenarios of depositing.
     * @param _tokenAddress address of the token being sent. 0x0 for eth
     * @param _contractType 0 for eth, 1 for erc20, 2 for erc721, 3 for erc1155
     * @param _amount amount of tokens being sent
     * @param _tokenId id of the token being sent if erc721 or erc1155
     * @param claimKey address derived from the link claim private key
     * @param _onBehalfOf who will be able to reclaim the link if the private key is lost
     * @param _withMFA whether an external authorisation is required for withdrawal
     * @param _recipient if not 0x00, only _recipient will be able to withdraw
     * @param _reclaimableAfter if _recipient is set, the sender can reclaim only after this timestamp
     * @return uint256 index of the deposit
     */
    function createCustomLink(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address claimKey,
        address _onBehalfOf,
        bool _withMFA,
        address _recipient,
        uint40 _reclaimableAfter
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeLink(
            _tokenAddress,
            _contractType,
            _amount,
            _tokenId,
            claimKey,
            _onBehalfOf,
            _withMFA,
            _recipient,
            _reclaimableAfter,
            0,
            0,
            false
        );
    }

    /**
     * @notice Create a link and collect backend-authorized service/gasless fees up front.
     * @dev Non-zero fees are paid in `feeToken` by msg.sender. `gaslessFee > 0` or
     *      `gaslessSponsored == true` marks the link as eligible for EnvelopePaymaster-sponsored
     *      claim or sender reclaim. The fee authorization is signed by `mfaAuthorizer` and includes
     *      the full deposit intent plus a deadline.
     */
    function createLinkWithFees(LinkRequest calldata _request, FeeAuthorization calldata _feeAuthorization)
        public
        payable
        nonReentrant
        returns (uint256)
    {
        _verifyFeeAuthorization(_request, _feeAuthorization);
        uint256 amount =
            _pullTokensViaApproval(_request.tokenAddress, _request.contractType, _request.amount, _request.tokenId);

        uint256 index = links.length;
        _collectLinkFees(index, msg.sender, _feeAuthorization.serviceFee, _feeAuthorization.gaslessFee);

        return _storeLink(
            _request.tokenAddress,
            _request.contractType,
            amount,
            _request.tokenId,
            _request.claimKey,
            _request.onBehalfOf,
            _request.withMFA,
            _request.recipient,
            _request.reclaimableAfter,
            _feeAuthorization.serviceFee,
            _feeAuthorization.gaslessFee,
            _feeAuthorization.gaslessSponsored
        );
    }

    /// @notice Create many same-shape links in one transaction.
    /// @dev The caller remains the recorded sender for every deposit and keeps reclaim rights.
    ///      ERC-721 is intentionally excluded here because each NFT needs a distinct tokenId.
    ///      Reverts if the actually-received total is not evenly divisible across all links to
    ///      prevent silent dust loss when fee-on-transfer tokens are used.
    function createLinks(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address[] calldata _claimKeys
    ) external payable nonReentrant returns (uint256[] memory) {
        if (_claimKeys.length == 0) return new uint256[](0);
        uint256 totalAmount = _amount * _claimKeys.length;
        uint256 actualTotal = _pullUniformBatchAssets(msg.sender, _tokenAddress, _contractType, totalAmount, _tokenId);
        if (actualTotal % _claimKeys.length != 0) revert UnevenBatchAmount();
        uint256 perLinkAmount = actualTotal / _claimKeys.length;

        uint256[] memory linkIndexes = new uint256[](_claimKeys.length);
        for (uint256 i = 0; i < _claimKeys.length; ++i) {
            linkIndexes[i] = _storeLink(
                _tokenAddress,
                _contractType,
                perLinkAmount,
                _tokenId,
                _claimKeys[i],
                msg.sender,
                false,
                address(0),
                0,
                0,
                0,
                false
            );
        }
        return linkIndexes;
    }

    /// @notice Same as createLinks, but avoids allocating and returning the indexes array.
    function createLinksNoReturn(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address[] calldata _claimKeys
    ) external payable nonReentrant {
        if (_claimKeys.length == 0) return;
        uint256 totalAmount = _amount * _claimKeys.length;
        uint256 actualTotal = _pullUniformBatchAssets(msg.sender, _tokenAddress, _contractType, totalAmount, _tokenId);
        if (actualTotal % _claimKeys.length != 0) revert UnevenBatchAmount();
        uint256 perLinkAmount = actualTotal / _claimKeys.length;

        for (uint256 i = 0; i < _claimKeys.length; ++i) {
            _storeLink(
                _tokenAddress,
                _contractType,
                perLinkAmount,
                _tokenId,
                _claimKeys[i],
                msg.sender,
                false,
                address(0),
                0,
                0,
                0,
                false
            );
        }
    }

    /// @notice Create a heterogeneous batch of no-fee links.
    /// @dev Supports ETH, ERC-20, ERC-721, and ERC-1155. Recipient binding is intentionally
    ///      left to createCustomLinksWithFees via LinkRequest[].
    function createCustomLinks(
        address[] calldata _tokenAddresses,
        uint8[] calldata _contractTypes,
        uint256[] calldata _amounts,
        uint256[] calldata _tokenIds,
        address[] calldata _claimKeys,
        bool[] calldata _withMFAs
    ) external payable nonReentrant returns (uint256[] memory) {
        _validateBatchArrayLengths(
            _tokenAddresses.length,
            _contractTypes.length,
            _amounts.length,
            _tokenIds.length,
            _claimKeys.length,
            _withMFAs.length
        );

        _validateCustomLinksPayment(_contractTypes, _amounts);

        uint256[] memory linkIndexes = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; ++i) {
            linkIndexes[i] = _createNoFeeCustomLink(
                _tokenAddresses[i], _contractTypes[i], _amounts[i], _tokenIds[i], _claimKeys[i], _withMFAs[i]
            );
        }
        return linkIndexes;
    }

    /// @notice Create a heterogeneous batch of links with backend-authorized fees.
    /// @dev Fee authorizations are signed for the real caller because batching is vault-native.
    function createCustomLinksWithFees(LinkRequest[] calldata _requests, FeeAuthorization[] calldata _feeAuthorizations)
        external
        payable
        nonReentrant
        returns (uint256[] memory)
    {
        if (_requests.length != _feeAuthorizations.length) {
            revert ParametersLengthMismatch();
        }

        uint256 expectedEther;
        for (uint256 i = 0; i < _requests.length; ++i) {
            if (_requests[i].contractType > 3) revert InvalidContractType();
            if (_requests[i].contractType == 0) expectedEther += _requests[i].amount;
            _verifyFeeAuthorization(_requests[i], _feeAuthorizations[i]);
        }
        if (msg.value != expectedEther) revert InvalidTotalEtherSent();

        uint256[] memory linkIndexes = new uint256[](_requests.length);
        for (uint256 i = 0; i < _requests.length; ++i) {
            linkIndexes[i] = _createCustomLinkWithFees(_requests[i], _feeAuthorizations[i]);
        }

        return linkIndexes;
    }

    /// @notice Create raffle-style ETH or ERC-20 links sharing one claimKey and different amounts.
    function createRaffleLinks(
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address claimKey
    ) external payable nonReentrant returns (uint256[] memory) {
        return _createRaffleLinks(_tokenAddress, _contractType, _amounts, claimKey, false);
    }

    /// @notice Create MFA-gated raffle-style ETH or ERC-20 links sharing one claimKey.
    function createMFARaffleLinks(
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address claimKey
    ) external payable nonReentrant returns (uint256[] memory) {
        return _createRaffleLinks(_tokenAddress, _contractType, _amounts, claimKey, true);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Claim Functions
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw tokens. Can be called by anyone with a valid signature.
     */
    function claim(uint256 _index, address _recipientAddress, bytes memory _signature)
        external
        nonReentrant
        returns (bool)
    {
        return _executeClaim(_index, _recipientAddress, OPEN_CLAIM_MODE, _signature, false);
    }

    /**
     * @notice Withdraw tokens with backend MFA approval.
     * @dev Reverts if the target link does not require MFA; use plain {claim} for non-MFA links.
     * @param _index deposit index
     * @param _recipientAddress address to receive the full deposit amount
     * @param _signature withdrawal signature from the link's claimKey
     * @param _MFASignature backend signature authorizing this withdrawal
     * @param _deadline backend-provided signature deadline; 0 means no expiry
     */
    function claimWithMFA(
        uint256 _index,
        address _recipientAddress,
        bytes memory _signature,
        bytes memory _MFASignature,
        uint256 _deadline
    ) external nonReentrant returns (bool) {
        if (_index >= links.length) revert LinkIndexOutOfBounds();
        if (!links[_index].status.requiresMFA) revert MfaNotRequired();
        _verifyMfaSignature(_index, _recipientAddress, _deadline, _MFASignature);
        return _executeClaim(_index, _recipientAddress, OPEN_CLAIM_MODE, _signature, true);
    }

    /**
     * @notice Withdraw tokens from a recipient-bound link directly by the recipient.
     * @dev Bound links can also be claimed via plain {claim} when the caller has a claimKey signature
     *      over OPEN_CLAIM_MODE and the recipient matches. This entry uses BOUND_CLAIM_MODE so a
     *      bound-mode signature cannot be reused as an open-mode signature and vice versa.
     */
    function claimAsBoundRecipient(uint256 _index, address _recipientAddress, bytes memory _signature)
        external
        nonReentrant
        returns (bool)
    {
        if (_recipientAddress != msg.sender) revert NotTheRecipient();
        if (_index >= links.length) revert LinkIndexOutOfBounds();
        if (links[_index].parties.recipient == address(0)) revert LinkNotRecipientBound();
        return _executeClaim(_index, _recipientAddress, BOUND_CLAIM_MODE, _signature, false);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Creator Reclaim Functions
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Creator reclaims their link directly.
     */
    function reclaim(uint256 _index) external nonReentrant returns (bool) {
        return _executeReclaim(_index, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Token Receiver Hooks
    // ══════════════════════════════════════════════════════════════════════════════

    function onERC721Received(address _operator, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (_operator != address(this)) revert DirectTransfersNotAllowed();
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address _operator, address, uint256, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (_operator != address(this)) revert DirectTransfersNotAllowed();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address _operator, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (_operator != address(this)) revert DirectTransfersNotAllowed();
        return this.onERC1155BatchReceived.selector;
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Owner Functions
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update the MFA authorizer address. Only callable by owner.
     * @dev Reverts on address(0) — the protocol requires an always-set authorizer for MFA claims
     *      and fee-authorized creation. To replace a compromised key, rotate to a new non-zero address.
     * @param _newAuthorizer new MFA signer address.
     */
    function setMfaAuthorizer(address _newAuthorizer) external onlyOwner {
        if (_newAuthorizer == address(0)) revert ZeroMfaAuthorizer();
        emit MfaAuthorizerUpdated(mfaAuthorizer, _newAuthorizer);
        mfaAuthorizer = _newAuthorizer;
    }

    /**
     * @notice Withdraw accumulated feeToken fees to the caller (owner). ETH fees are not supported.
     */
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFeesToWithdraw();
        accumulatedFees = 0;

        feeToken.safeTransfer(msg.sender, amount);

        emit FeesWithdrawn(address(feeToken), amount);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // View Functions
    // ══════════════════════════════════════════════════════════════════════════════

    function getSigner(bytes32 messageHash, bytes memory signature) public pure returns (address) {
        return ECDSA.recover(messageHash, signature);
    }

    /// @notice Returns whether `caller` can use an EnvelopePaymaster for the encoded vault call.
    /// @dev Intended for ZkSync paymaster validation. Re-checks claim/reclaim preconditions so the
    ///      paymaster only pays for prepaid gasless links that should execute successfully.
    function isValidGaslessOperation(address caller, bytes calldata callData) external view returns (bool) {
        if (callData.length < 4) return false;

        bytes4 selector = bytes4(callData[0:4]);

        if (selector == this.claim.selector) {
            (uint256 index, address recipient, bytes memory signature) =
                abi.decode(callData[4:], (uint256, address, bytes));
            return _isValidGaslessClaim(caller, index, recipient, OPEN_CLAIM_MODE, signature, false);
        }

        if (selector == this.claimAsBoundRecipient.selector) {
            (uint256 index, address recipient, bytes memory signature) =
                abi.decode(callData[4:], (uint256, address, bytes));
            if (!_isRecipientBoundLink(index)) return false;
            return _isValidGaslessClaim(caller, index, recipient, BOUND_CLAIM_MODE, signature, false);
        }

        if (selector == this.claimWithMFA.selector) {
            (uint256 index, address recipient, bytes memory signature, bytes memory mfaSignature, uint256 deadline) =
                abi.decode(callData[4:], (uint256, address, bytes, bytes, uint256));
            if (!_isMfaSignatureValid(index, recipient, deadline, mfaSignature)) return false;
            return _isValidGaslessClaim(caller, index, recipient, OPEN_CLAIM_MODE, signature, true);
        }

        if (selector == this.reclaim.selector) {
            (uint256 index) = abi.decode(callData[4:], (uint256));
            return _isValidGaslessReclaim(caller, index);
        }

        return false;
    }

    function getLinkCount() external view returns (uint256) {
        return links.length;
    }

    function getLinkStatus(uint256 _index) external view returns (LinkStatus memory) {
        return links[_index].status;
    }

    function getLinkAsset(uint256 _index) external view returns (LinkAsset memory) {
        return links[_index].asset;
    }

    function getLinkParties(uint256 _index) external view returns (LinkParties memory) {
        return links[_index].parties;
    }

    function getLinkFees(uint256 _index) external view returns (LinkFees memory) {
        return links[_index].fees;
    }

    function getAllLinkIndexes() external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](links.length);
        for (uint256 i = 0; i < links.length; ++i) {
            result[i] = i;
        }
        return result;
    }

    function getLinkIndexesCreatedBy(address _address) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < links.length; ++i) {
            if (links[i].parties.creator == _address) {
                count++;
            }
        }
        uint256[] memory result = new uint256[](count);
        count = 0;
        for (uint256 i = 0; i < links.length; ++i) {
            if (links[i].parties.creator == _address) {
                result[count] = i;
                count++;
            }
        }
        return result;
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Internal Functions
    // ══════════════════════════════════════════════════════════════════════════════

    function _verifyMfaSignature(
        uint256 _index,
        address _recipientAddress,
        uint256 _deadline,
        bytes memory _MFASignature
    ) internal view {
        // deadline == 0 means no expiry
        if (_deadline != 0 && block.timestamp > _deadline) revert MfaSignatureExpired();

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(MFA_APPROVAL_TYPEHASH, _index, _recipientAddress, _deadline)));
        if (_recoverSigner(digest, _MFASignature) != mfaAuthorizer) revert WrongMfaSignature();
    }

    function _isMfaSignatureValid(uint256 _index, address _recipientAddress, uint256 _deadline, bytes memory _signature)
        internal
        view
        returns (bool)
    {
        if (_deadline != 0 && block.timestamp > _deadline) return false;

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(MFA_APPROVAL_TYPEHASH, _index, _recipientAddress, _deadline)));
        return _recoverSigner(digest, _signature) == mfaAuthorizer;
    }

    function _verifyFeeAuthorization(LinkRequest calldata _request, FeeAuthorization calldata _feeAuthorization)
        internal
    {
        uint256 totalFee = _feeAuthorization.serviceFee + _feeAuthorization.gaslessFee;
        if (totalFee == 0 && !_feeAuthorization.gaslessSponsored && _feeAuthorization.signature.length == 0) return;
        if (totalFee > 0 && address(feeToken) == address(0)) revert FeeTokenNotConfigured();
        if (_feeAuthorization.deadline != 0 && block.timestamp > _feeAuthorization.deadline) {
            revert FeeAuthorizationExpired();
        }

        bytes32 digest = _feeAuthorizationDigest(_request, _feeAuthorization, msg.sender);

        // Replay protection keyed by the EIP-712 digest: each (intent, feePayer, deadline) tuple may be
        // consumed exactly once, regardless of the on-the-wire signature encoding.
        if (usedFeeAuthorizations[digest]) revert FeeAuthorizationAlreadyUsed();
        usedFeeAuthorizations[digest] = true;

        if (_recoverSigner(digest, _feeAuthorization.signature) != mfaAuthorizer) {
            revert WrongFeeAuthorizationSignature();
        }
    }

    function _feeAuthorizationDigest(
        LinkRequest calldata _request,
        FeeAuthorization calldata _feeAuthorization,
        address _feePayer
    ) internal view returns (bytes32) {
        // Split abi.encode into two parts to avoid stack-too-deep without viaIR.
        // abi.encodePacked(abi.encode(a..h), abi.encode(i..n)) == abi.encode(a..n)
        // because abi.encode already pads each value to 32 bytes.
        return _hashTypedDataV4(
            keccak256(
                abi.encodePacked(
                    abi.encode(
                        FEE_AUTHORIZATION_TYPEHASH,
                        _feePayer,
                        _request.tokenAddress,
                        _request.contractType,
                        _request.amount,
                        _request.tokenId,
                        _request.claimKey,
                        _request.onBehalfOf
                    ),
                    abi.encode(
                        _request.withMFA,
                        _request.recipient,
                        _request.reclaimableAfter,
                        _feeAuthorization.serviceFee,
                        _feeAuthorization.gaslessFee,
                        _feeAuthorization.gaslessSponsored,
                        _feeAuthorization.deadline
                    )
                )
            )
        );
    }

    function _collectLinkFees(uint256 _index, address _feePayer, uint256 _serviceFee, uint256 _gaslessFee) internal {
        uint256 totalFee = _serviceFee + _gaslessFee;
        if (totalFee > 0) {
            address tokenAddress = address(feeToken);
            uint256 balanceBefore = feeToken.balanceOf(address(this));
            feeToken.safeTransferFrom(_feePayer, address(this), totalFee);
            uint256 actualReceived = feeToken.balanceOf(address(this)) - balanceBefore;
            if (actualReceived != totalFee) revert FeeTokenTransferAmountMismatch();
            accumulatedFees += totalFee;
            emit FeeCollected(_index, tokenAddress, _serviceFee, _gaslessFee);
        }
    }

    function _storeLink(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address claimKey,
        address _onBehalfOf,
        bool _requiresMFA,
        address _recipient,
        uint40 _reclaimableAfter,
        uint256 _serviceFee,
        uint256 _gaslessFee,
        bool _gaslessSponsored
    ) internal returns (uint256) {
        // A link must be claimable: either via a claim-key signature, or by a bound recipient.
        // Rejecting `claimKey == 0 && recipient == 0` prevents accidentally creating an
        // unbound link that anyone could drain with an empty signature.
        if (claimKey == address(0) && _recipient == address(0)) revert ZeroClaimKey();
        uint256 index = links.length;
        links.push();

        {
            Link storage link = links[index];
            link.status.claimKey = claimKey;
            link.status.requiresMFA = _requiresMFA;
            link.status.gaslessSponsored = _gaslessSponsored;
            link.status.timestamp = uint40(block.timestamp);
            link.asset.tokenAddress = _tokenAddress;
            link.asset.contractType = _contractType;
            link.asset.amount = _amount;
            link.asset.tokenId = _tokenId;
            link.parties.creator = _onBehalfOf;
            link.parties.recipient = _recipient;
            link.parties.reclaimableAfter = _reclaimableAfter;
            link.fees.serviceFee = _serviceFee;
            link.fees.gaslessFee = _gaslessFee;
        }

        emit LinkCreated(index, _contractType, _amount, _onBehalfOf);
        return index;
    }

    function _isValidGaslessClaim(
        address _caller,
        uint256 _index,
        address _recipientAddress,
        bytes32 _extraData,
        bytes memory _signature,
        bool _authorized
    ) internal view returns (bool) {
        if (_caller != _recipientAddress) return false;
        if (_index >= links.length) return false;
        Link storage link = links[_index];
        if (link.fees.gaslessFee == 0 && !link.status.gaslessSponsored) return false;
        return _isValidClaim(_index, _recipientAddress, _extraData, _signature, _authorized);
    }

    function _isRecipientBoundLink(uint256 _index) internal view returns (bool) {
        return _index < links.length && links[_index].parties.recipient != address(0);
    }

    function _isValidClaim(
        uint256 _index,
        address _recipientAddress,
        bytes32 _extraData,
        bytes memory _signature,
        bool _authorized
    ) internal view returns (bool) {
        if (_recipientAddress == address(0)) return false;
        Link memory deposit = links[_index];
        if (deposit.status.redeemed) return false;
        if (deposit.status.requiresMFA && !_authorized) return false;
        if (deposit.parties.recipient != address(0) && _recipientAddress != deposit.parties.recipient) return false;

        if (deposit.status.claimKey != address(0)) {
            bytes32 _claimHash =
                _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, _index, _recipientAddress, _extraData)));
            if (_recoverSigner(_claimHash, _signature) != deposit.status.claimKey) return false;
        }

        return true;
    }

    function _isValidGaslessReclaim(address _caller, uint256 _index) internal view returns (bool) {
        if (_index >= links.length) return false;
        Link memory deposit = links[_index];
        if (deposit.fees.gaslessFee == 0 && !deposit.status.gaslessSponsored) return false;
        if (deposit.status.redeemed) return false;
        if (deposit.parties.creator != _caller) return false;
        if (deposit.parties.recipient != address(0) && block.timestamp <= deposit.parties.reclaimableAfter) {
            return false;
        }
        return true;
    }

    function _recoverSigner(bytes32 _digest, bytes memory _signature) internal pure returns (address) {
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(_digest, _signature);
        if (error != ECDSA.RecoverError.NoError) return address(0);
        return recovered;
    }

    function _validateBatchArrayLengths(
        uint256 _tokenAddressesLength,
        uint256 _contractTypesLength,
        uint256 _amountsLength,
        uint256 _tokenIdsLength,
        uint256 _claimKeysLength,
        uint256 _withMFAsLength
    ) internal pure {
        if (
            _tokenAddressesLength != _claimKeysLength || _contractTypesLength != _claimKeysLength
                || _amountsLength != _claimKeysLength || _tokenIdsLength != _claimKeysLength
                || _withMFAsLength != _claimKeysLength
        ) revert ParametersLengthMismatch();
    }

    function _validateCustomLinksPayment(uint8[] calldata _contractTypes, uint256[] calldata _amounts) internal view {
        uint256 expectedEther;
        for (uint256 i = 0; i < _amounts.length; ++i) {
            if (_contractTypes[i] > 3) revert InvalidContractType();
            if (_contractTypes[i] == 0) expectedEther += _amounts[i];
        }
        if (msg.value != expectedEther) revert InvalidTotalEtherSent();
    }

    function _createNoFeeCustomLink(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address claimKey,
        bool _withMFA
    ) internal returns (uint256) {
        uint256 amount = _pullTokensViaApprovalFrom(
            msg.sender, _tokenAddress, _contractType, _amount, _tokenId, _contractType == 0 ? _amount : 0
        );
        return _storeLink(
            _tokenAddress, _contractType, amount, _tokenId, claimKey, msg.sender, _withMFA, address(0), 0, 0, 0, false
        );
    }

    function _createCustomLinkWithFees(LinkRequest calldata request, FeeAuthorization calldata feeAuthorization)
        internal
        returns (uint256)
    {
        uint256 amount = _pullTokensViaApprovalFrom(
            msg.sender,
            request.tokenAddress,
            request.contractType,
            request.amount,
            request.tokenId,
            request.contractType == 0 ? request.amount : 0
        );

        uint256 index = links.length;
        _collectLinkFees(index, msg.sender, feeAuthorization.serviceFee, feeAuthorization.gaslessFee);
        return _storeLink(
            request.tokenAddress,
            request.contractType,
            amount,
            request.tokenId,
            request.claimKey,
            request.onBehalfOf,
            request.withMFA,
            request.recipient,
            request.reclaimableAfter,
            feeAuthorization.serviceFee,
            feeAuthorization.gaslessFee,
            feeAuthorization.gaslessSponsored
        );
    }

    function _pullUniformBatchAssets(
        address _from,
        address _tokenAddress,
        uint8 _contractType,
        uint256 _totalAmount,
        uint256 _tokenId
    ) internal returns (uint256) {
        if (_contractType == 0) {
            if (msg.value != _totalAmount) revert InvalidTotalEtherSent();
            return _totalAmount;
        }
        if (msg.value != 0) revert EthNotAcceptedForNonEthLink();

        if (_contractType == 1) {
            if (_totalAmount > 0) {
                uint256 balanceBefore = IERC20(_tokenAddress).balanceOf(address(this));
                IERC20(_tokenAddress).safeTransferFrom(_from, address(this), _totalAmount);
                return IERC20(_tokenAddress).balanceOf(address(this)) - balanceBefore;
            }
            return 0;
        } else if (_contractType == 2) {
            revert Erc721BatchNotSupported();
        } else if (_contractType == 3) {
            if (_totalAmount > 0) {
                IERC1155(_tokenAddress).safeTransferFrom(_from, address(this), _tokenId, _totalAmount, "");
            }
            return _totalAmount;
        } else {
            revert InvalidContractType();
        }
    }

    function _createRaffleLinks(
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address claimKey,
        bool _requiresMFA
    ) internal returns (uint256[] memory) {
        if (_contractType != 0 && _contractType != 1) {
            revert UnsupportedRaffleContractType();
        }

        uint256 totalAmount;
        for (uint256 i = 0; i < _amounts.length; ++i) {
            totalAmount += _amounts[i];
        }

        if (_contractType == 0) {
            if (msg.value != totalAmount) revert InvalidTotalEtherSent();
        } else {
            if (msg.value != 0) revert EthNotAcceptedForNonEthLink();
            if (totalAmount > 0) {
                uint256 balanceBefore = IERC20(_tokenAddress).balanceOf(address(this));
                IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), totalAmount);
                uint256 actualReceived = IERC20(_tokenAddress).balanceOf(address(this)) - balanceBefore;
                if (actualReceived < totalAmount) revert InsufficientTokensReceived();
            }
        }

        uint256[] memory linkIndexes = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; ++i) {
            linkIndexes[i] = _storeLink(
                _tokenAddress,
                _contractType,
                _amounts[i],
                0,
                claimKey,
                msg.sender,
                _requiresMFA,
                address(0),
                0,
                0,
                0,
                false
            );
        }
        return linkIndexes;
    }

    function _pullTokensViaApproval(address _tokenAddress, uint8 _contractType, uint256 _amount, uint256 _tokenId)
        internal
        returns (uint256)
    {
        return _pullTokensViaApprovalFrom(msg.sender, _tokenAddress, _contractType, _amount, _tokenId, msg.value);
    }

    function _pullTokensViaApprovalFrom(
        address _from,
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        uint256 _ethAmount
    ) internal returns (uint256) {
        if (_contractType > 3) revert InvalidContractType();

        if (_contractType == 0) {
            if (_amount != _ethAmount) revert WrongEthAmount();
        } else if (_ethAmount != 0) {
            revert EthNotAcceptedForNonEthLink();
        } else if (_contractType == 1) {
            uint256 balanceBefore = IERC20(_tokenAddress).balanceOf(address(this));
            IERC20(_tokenAddress).safeTransferFrom(_from, address(this), _amount);
            _amount = IERC20(_tokenAddress).balanceOf(address(this)) - balanceBefore;
        } else if (_contractType == 2) {
            if (_amount != 1) revert Erc721AmountMustBeOne();
            IERC721(_tokenAddress).safeTransferFrom(_from, address(this), _tokenId, "Internal transfer");
        } else if (_contractType == 3) {
            IERC1155(_tokenAddress).safeTransferFrom(_from, address(this), _tokenId, _amount, "Internal transfer");
        }

        return _amount;
    }

    function _executeClaim(
        uint256 _index,
        address _recipientAddress,
        bytes32 _extraData,
        bytes memory _signature,
        bool _authorized
    ) internal returns (bool) {
        if (_recipientAddress == address(0)) revert ZeroRecipientAddress();
        if (_index >= links.length) revert LinkIndexOutOfBounds();
        Link memory link = links[_index];
        if (link.status.redeemed) revert LinkAlreadyRedeemed();

        address claimSigner;
        if (_signature.length > 0) {
            bytes32 _claimHash =
                _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, _index, _recipientAddress, _extraData)));
            claimSigner = getSigner(_claimHash, _signature);
        }
        if (link.status.requiresMFA && !_authorized) revert RequiresMfaAuthorization();
        if (link.status.claimKey != address(0) && claimSigner != link.status.claimKey) revert WrongSignature();
        if (link.parties.recipient != address(0) && _recipientAddress != link.parties.recipient) {
            revert WrongRecipient();
        }

        emit LinkRedeemed(_index, link.asset.contractType, link.asset.amount, _recipientAddress);
        links[_index].status.redeemed = true;

        if (link.asset.contractType == 0) {
            (bool success,) = _recipientAddress.call{value: link.asset.amount}("");
            if (!success) revert EthTransferFailed();
        } else if (link.asset.contractType == 1) {
            IERC20(link.asset.tokenAddress).safeTransfer(_recipientAddress, link.asset.amount);
        } else if (link.asset.contractType == 2) {
            IERC721(link.asset.tokenAddress).safeTransferFrom(address(this), _recipientAddress, link.asset.tokenId);
        } else if (link.asset.contractType == 3) {
            IERC1155(link.asset.tokenAddress)
                .safeTransferFrom(address(this), _recipientAddress, link.asset.tokenId, link.asset.amount, "");
        }

        return true;
    }

    function _executeReclaim(uint256 _index, address _creator) internal returns (bool) {
        if (_index >= links.length) revert LinkIndexOutOfBounds();
        Link memory link = links[_index];
        if (link.status.redeemed) revert LinkAlreadyRedeemed();
        if (link.parties.creator != _creator) revert NotTheCreator();
        if (link.parties.recipient != address(0)) {
            if (block.timestamp <= link.parties.reclaimableAfter) revert TooEarlyToReclaim();
        }

        emit LinkRedeemed(_index, link.asset.contractType, link.asset.amount, link.parties.creator);
        links[_index].status.redeemed = true;

        if (link.asset.contractType == 0) {
            (bool success,) = payable(link.parties.creator).call{value: link.asset.amount}("");
            if (!success) revert EthTransferFailed();
        } else if (link.asset.contractType == 1) {
            IERC20(link.asset.tokenAddress).safeTransfer(link.parties.creator, link.asset.amount);
        } else if (link.asset.contractType == 2) {
            IERC721(link.asset.tokenAddress).safeTransferFrom(address(this), link.parties.creator, link.asset.tokenId);
        } else if (link.asset.contractType == 3) {
            IERC1155(link.asset.tokenAddress)
                .safeTransferFrom(address(this), link.parties.creator, link.asset.tokenId, link.asset.amount, "");
        }

        return true;
    }
}
