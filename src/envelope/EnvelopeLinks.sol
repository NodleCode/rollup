// SPDX-License-Identifier: GPL-3.0-or-later
// Originally derived from peanutprotocol/peanut-contracts (V4.4).
// Full GPL v3 text: src/envelope/LICENSE-GPL
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract EnvelopeLinks is IERC721Receiver, IERC1155Receiver, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Custom Errors ────────────────────────────────────────────────────────────

    error InvalidContractType();
    error WrongEthAmount();
    error Erc721AmountMustBeOne();
    error LinkIndexOutOfBounds();
    error LinkAlreadyRedeemed();
    error RequiresMfaAuthorization();
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
    error MfaAuthorizerIsZero();

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

    // We may include this hash in peanut-specific signatures to make sure
    // that the message signed by the user has effects only in peanut contracts.
    bytes32 public constant ENVELOPE_SALT = 0x70adbbeba9d4f0c82e28dd574f15466f75df0543b65f24460fc445813b5d94e0; // keccak256("Konrad makes tokens go woosh tadam");

    bytes32 public constant OPEN_CLAIM_MODE = 0x0000000000000000000000000000000000000000000000000000000000000000; // default. Any address can trigger the withdrawal function
    bytes32 public constant BOUND_CLAIM_MODE = 0x2bb5bef2b248d3edba501ad918c3ab524cce2aea54d4c914414e1c4401dc4ff4; // keccak256("only recipient") - only the signed recipient can trigger the withdrawal function

    /// @notice Address authorized to issue MFA signatures gating claimWithMFA calls and fee authorizations.
    /// @dev Rotatable by owner. Address(0) disables MFA — claimWithMFA will revert.
    address public mfaAuthorizer;

    Link[] internal links; // array of links

    /// @notice ERC-20 token used for Envelope service and gasless sponsorship fees (for example NODL).
    IERC20 public immutable feeToken;

    /// @notice Accumulated fees per token address (address(0) for ETH; feeToken for link-creation fees).
    mapping(address => uint256) public accumulatedFees;

    /// @notice Tracks consumed fee authorizations to prevent replay.
    mapping(bytes32 => bool) public usedFeeAuthorizations;

    // events
    event LinkCreated(uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _creator);
    event LinkRedeemed(
        uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _recipientAddress
    );
    event FeeCollected(uint256 indexed _index, address indexed tokenAddress, uint256 serviceFee, uint256 gaslessFee);
    event FeesWithdrawn(address indexed tokenAddress, uint256 amount);
    event MfaAuthorizerUpdated(address indexed oldAuthorizer, address indexed newAuthorizer);

    /// @param _mfaAuthorizer address authorized to sign backend fee and MFA approvals (use address(0) to disable).
    /// @param _owner initial owner of the contract (receives accumulated fees).
    /// @param _feeToken ERC-20 token used for fees; address(0) disables non-zero fee authorizations.
    constructor(address _mfaAuthorizer, address _owner, address _feeToken) Ownable(_owner) {
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
    function createLinks(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address[] calldata _claimKeys
    ) external payable nonReentrant returns (uint256[] memory) {
        uint256 totalAmount = _amount * _claimKeys.length;
        uint256 actualTotal = _pullUniformBatchAssets(msg.sender, _tokenAddress, _contractType, totalAmount, _tokenId);
        uint256 perLinkAmount = _claimKeys.length > 0 ? actualTotal / _claimKeys.length : 0;

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
        uint256 totalAmount = _amount * _claimKeys.length;
        uint256 actualTotal = _pullUniformBatchAssets(msg.sender, _tokenAddress, _contractType, totalAmount, _tokenId);
        uint256 perLinkAmount = _claimKeys.length > 0 ? actualTotal / _claimKeys.length : 0;

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
        _verifyMfaSignature(_index, _recipientAddress, _deadline, _MFASignature);
        return _executeClaim(_index, _recipientAddress, OPEN_CLAIM_MODE, _signature, true);
    }

    /**
     * @notice Withdraw tokens. Must be called by the recipient.
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
     * @param _newAuthorizer new MFA signer address (address(0) disables MFA).
     */
    function setMfaAuthorizer(address _newAuthorizer) external onlyOwner {
        emit MfaAuthorizerUpdated(mfaAuthorizer, _newAuthorizer);
        mfaAuthorizer = _newAuthorizer;
    }

    /**
     * @notice Withdraw accumulated fees for a given token. Only callable by owner.
     * @param _tokenAddress token to withdraw fees for (address(0) for ETH)
     */
    function withdrawFees(address _tokenAddress) external onlyOwner nonReentrant {
        uint256 amount = accumulatedFees[_tokenAddress];
        if (amount == 0) revert NoFeesToWithdraw();
        accumulatedFees[_tokenAddress] = 0;

        if (_tokenAddress == address(0)) {
            (bool success,) = msg.sender.call{value: amount}("");
            if (!success) revert EthTransferFailed();
        } else {
            IERC20(_tokenAddress).safeTransfer(msg.sender, amount);
        }

        emit FeesWithdrawn(_tokenAddress, amount);
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
        if (mfaAuthorizer == address(0)) revert MfaAuthorizerIsZero();
        // deadline == 0 means no expiry
        if (_deadline != 0 && block.timestamp > _deadline) revert MfaSignatureExpired();

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(ENVELOPE_SALT, block.chainid, address(this), _index, _recipientAddress, _deadline)
            )
        );
        address authorizationSigner = getSigner(digest, _MFASignature);
        if (authorizationSigner != mfaAuthorizer) revert WrongMfaSignature();
    }

    function _isMfaSignatureValid(uint256 _index, address _recipientAddress, uint256 _deadline, bytes memory _signature)
        internal
        view
        returns (bool)
    {
        if (mfaAuthorizer == address(0)) return false;
        if (_deadline != 0 && block.timestamp > _deadline) return false;

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(ENVELOPE_SALT, block.chainid, address(this), _index, _recipientAddress, _deadline)
            )
        );
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

        // Replay protection: mark this authorization as consumed.
        bytes32 authHash = keccak256(_feeAuthorization.signature);
        if (usedFeeAuthorizations[authHash]) revert FeeAuthorizationAlreadyUsed();
        usedFeeAuthorizations[authHash] = true;

        address authorizationSigner = getSigner(digest, _feeAuthorization.signature);
        if (authorizationSigner != mfaAuthorizer) revert WrongFeeAuthorizationSignature();
    }

    function _feeAuthorizationDigest(
        LinkRequest calldata _request,
        FeeAuthorization calldata _feeAuthorization,
        address _feePayer
    ) internal view returns (bytes32) {
        bytes memory encoded = new bytes(17 * 32);
        _writeFeeAuthorizationContext(encoded, _feePayer);
        _writeFeeAuthorizationAsset(
            encoded, _request.tokenAddress, _request.contractType, _request.amount, _request.tokenId
        );
        _writeFeeAuthorizationParties(
            encoded,
            _request.claimKey,
            _request.onBehalfOf,
            _request.withMFA,
            _request.recipient,
            _request.reclaimableAfter
        );
        _writeFeeAuthorizationFees(
            encoded,
            _feeAuthorization.serviceFee,
            _feeAuthorization.gaslessFee,
            _feeAuthorization.gaslessSponsored,
            _feeAuthorization.deadline
        );

        return MessageHashUtils.toEthSignedMessageHash(keccak256(encoded));
    }

    function _writeFeeAuthorizationContext(bytes memory encoded, address _feePayer) internal view {
        bytes32 salt = ENVELOPE_SALT;
        assembly ("memory-safe") {
            let ptr := add(encoded, 32)
            mstore(ptr, salt)
            mstore(add(ptr, 32), chainid())
            mstore(add(ptr, 64), address())
            mstore(add(ptr, 96), _feePayer)
        }
    }

    function _writeFeeAuthorizationAsset(
        bytes memory encoded,
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId
    ) internal pure {
        assembly ("memory-safe") {
            let ptr := add(encoded, 160)
            mstore(ptr, _tokenAddress)
            mstore(add(ptr, 32), _contractType)
            mstore(add(ptr, 64), _amount)
            mstore(add(ptr, 96), _tokenId)
        }
    }

    function _writeFeeAuthorizationParties(
        bytes memory encoded,
        address claimKey,
        address _onBehalfOf,
        bool _withMFA,
        address _recipient,
        uint40 _reclaimableAfter
    ) internal pure {
        assembly ("memory-safe") {
            let ptr := add(encoded, 288)
            mstore(ptr, claimKey)
            mstore(add(ptr, 32), _onBehalfOf)
            mstore(add(ptr, 64), _withMFA)
            mstore(add(ptr, 96), _recipient)
            mstore(add(ptr, 128), _reclaimableAfter)
        }
    }

    function _writeFeeAuthorizationFees(
        bytes memory encoded,
        uint256 _serviceFee,
        uint256 _gaslessFee,
        bool _gaslessSponsored,
        uint256 _deadline
    ) internal pure {
        assembly ("memory-safe") {
            let ptr := add(encoded, 448)
            mstore(ptr, _serviceFee)
            mstore(add(ptr, 32), _gaslessFee)
            mstore(add(ptr, 64), _gaslessSponsored)
            mstore(add(ptr, 96), _deadline)
        }
    }

    function _collectLinkFees(uint256 _index, address _feePayer, uint256 _serviceFee, uint256 _gaslessFee) internal {
        uint256 totalFee = _serviceFee + _gaslessFee;
        if (totalFee > 0) {
            address tokenAddress = address(feeToken);
            feeToken.safeTransferFrom(_feePayer, address(this), totalFee);
            accumulatedFees[tokenAddress] += totalFee;
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
            bytes32 _claimHash = MessageHashUtils.toEthSignedMessageHash(
                keccak256(
                    abi.encodePacked(ENVELOPE_SALT, block.chainid, address(this), _index, _recipientAddress, _extraData)
                )
            );
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
            bytes32 _claimHash = MessageHashUtils.toEthSignedMessageHash(
                keccak256(
                    abi.encodePacked(ENVELOPE_SALT, block.chainid, address(this), _index, _recipientAddress, _extraData)
                )
            );
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
