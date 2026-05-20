// SPDX-License-Identifier: GPL-3.0-or-later
//
// Modified by Nodle (2026-05-12) — see src/envelope/doc/EnvelopeVault.md ("Vendoring
// patches applied at import") and the git history of this file for the full patch set.
// The upstream source is peanutprotocol/peanut-contracts@main; the full GNU GPL v3
// license text is bundled at src/envelope/V4/LICENSE-GPL.
pragma solidity ^0.8.26;

//////////////////////////////////////////////////////////////////////////////////////
// @title   Peanut Protocol
// @notice  This contract is used to send non front-runnable link payments. These can
//          be erc20, erc721, erc1155 or just plain eth. The recipient address is arbitrary.
//          Links use asymmetric ECDSA encryption by default to be secure & enable trustless,
//          gasless claiming.
//          more at: https://peanut.to
// @version 0.4.4
// @author  Squirrel Labs
//////////////////////////////////////////////////////////////////////////////////////
//⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
//                         ⠀⠀⢀⣀⠀⠀⠀⠀⠀⠀
// ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⣶⣶⣦⣌⠙⠋⢡⣴⣶⡄⠀⠀
// ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠀⣿⣿⣿⡿⢋⣠⣶⣶⡌⠻⣿⠟⠀⠀
// ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⡆⠸⠟⢁⣴⣿⣿⣿⣿⣿⡦⠉⣴⡇⠀
// ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣾⣿⠟⠀⠰⣿⣿⣿⣿⣿⣿⠟⣠⡄⠹⠀⠀
// ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⢸⡿⢋⣤⣿⣄⠙⣿⣿⡿⠟⣡⣾⣿⣿⠀⠀⠀
// ⠀⠀⠀⠀⠀⠀⠀⠀⣠⣴⣾⠿⠀⢠⣾⣿⣿⣿⣦⠈⠉⢠⣾⣿⣿⣿⠏⠀⠀⠀
// ⠀⠀⠀⠀⣀⣤⣦⣄⠙⠋⣠⣴⣿⣿⣿⣿⠿⠛⢁⣴⣦⡄⠙⠛⠋⠁⠀⠀⠀⠀
// ⠀⠀⢀⣾⣿⣿⠟⢁⣴⣦⡈⠻⣿⣿⡿⠁⡀⠚⠛⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
// ⠀⠀⠘⣿⠟⢁⣴⣿⣿⣿⣿⣦⡈⠛⢁⣼⡟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
// ⠀⢰⡦⠀⢴⣿⣿⣿⣿⣿⣿⣿⠟⢀⠘⠿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
// ⠀⠘⢀⣶⡀⠻⣿⣿⣿⣿⡿⠋⣠⣿⣷⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
// ⠀⠀⢿⣿⣿⣦⡈⠻⣿⠟⢁⣼⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
// ⠀⠀⠈⠻⣿⣿⣿⠖⢀⠐⠿⠟⠋⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
// ⠀⠀⠀⠀⠈⠉⠁⠀⠀⠀⠀⠀
//
//////////////////////////////////////////////////////////////////////////////////////

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

contract EnvelopeVault is IERC721Receiver, IERC1155Receiver, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Custom Errors ────────────────────────────────────────────────────────────

    error InvalidContractType();
    error WrongEthAmount();
    error Erc721AmountMustBeOne();
    error DepositIndexOutOfBounds();
    error DepositAlreadyClaimed();
    error RequiresMfaAuthorization();
    error WrongMfaSignature();
    error WrongSignature();
    error WrongRecipient();
    error NotTheRecipient();
    error NotTheSender();
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
    error EthNotAcceptedForNonEthDeposit();
    error Erc721BatchNotSupported();
    error UnsupportedRaffleContractType();

    // ── Data Structures ──────────────────────────────────────────────────────────

    struct Deposit {
        address pubKey20; // (20 bytes) last 20 bytes of the hash of the public key for the deposit
        uint256 amount; // (32 bytes) amount of the asset being sent
        ///// tokenAddress, contractType, tokenId, claimed & timestamp are stored in a single 32 byte word
        address tokenAddress; // (20 bytes) address of the asset being sent. 0x0 for eth
        uint8 contractType; // (1 byte) 0 for eth, 1 for erc20, 2 for erc721, 3 for erc1155
        bool claimed; // (1 byte) has this deposit been claimed
        bool requiresMFA; // (1 byte) is additional auth (MFA) required?
        bool gaslessSponsored; // (1 byte) can the paymaster sponsor this deposit without a prepaid gasless fee?
        uint40 timestamp; // ( 5 bytes) timestamp of the deposit
        /////
        uint256 tokenId; // (32 bytes) id of the token being sent (if erc721 or erc1155)
        address senderAddress; // (20 bytes) address of the sender
        ///// slot for address-bound links data
        address recipient; // unless it's 0x00, only this address can claim the link
        uint40 reclaimableAfter; // for address-bound links, the sender is able to re-claim only after this timestamp
        uint256 serviceFee; // backend-authorized service fee collected at deposit time
        uint256 gaslessFee; // prepaid gas sponsorship fee collected at deposit time
    } // 8 storage slots (32 byte each)

    /// @notice Full deposit intent covered by a backend fee authorization.
    struct DepositRequest {
        address tokenAddress;
        uint8 contractType;
        uint256 amount;
        uint256 tokenId;
        address pubKey20;
        address onBehalfOf;
        bool withMFA;
        address recipient;
        uint40 reclaimableAfter;
    }

    /// @notice Backend-signed fee bundle collected when a deposit is created.
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

    bytes32 public constant ANYONE_WITHDRAWAL_MODE = 0x0000000000000000000000000000000000000000000000000000000000000000; // default. Any address can trigger the withdrawal function
    bytes32 public constant RECIPIENT_WITHDRAWAL_MODE =
        0x2bb5bef2b248d3edba501ad918c3ab524cce2aea54d4c914414e1c4401dc4ff4; // keccak256("only recipient") - only the signed recipient can trigger the withdrawal function

    bytes32 public DOMAIN_SEPARATOR; // initialized in the constructor

    bytes32 public constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice Address authorized to issue MFA signatures gating withdrawMFADeposit calls.
    /// @dev Configurable per deployment. Address(0) disables MFA — withdrawMFADeposit will revert.
    address public immutable mfaAuthorizer;

    struct EIP712Domain {
        string name;
        string version;
        uint256 chainId;
        address verifyingContract;
    }

    Deposit[] public deposits; // array of deposits

    /// @notice ERC-20 token used for Envelope service and gasless sponsorship fees (for example NODL).
    IERC20 public immutable feeToken;

    /// @notice Accumulated fees per token address (address(0) for ETH; feeToken for deposit-time fees).
    mapping(address => uint256) public accumulatedFees;

    // events
    event DepositEvent(
        uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _senderAddress
    );
    event WithdrawEvent(
        uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _recipientAddress
    );
    event FeeCollected(uint256 indexed _index, address indexed tokenAddress, uint256 serviceFee, uint256 gaslessFee);
    event FeesWithdrawn(address indexed tokenAddress, uint256 amount);
    event MessageEvent(string message);

    /// @param _mfaAuthorizer address authorized to sign backend fee and MFA approvals (use address(0) to disable).
    /// @param _owner initial owner of the contract (receives accumulated fees).
    /// @param _feeToken ERC-20 token used for fees; address(0) disables non-zero fee authorizations.
    constructor(address _mfaAuthorizer, address _owner, address _feeToken) Ownable(_owner) {
        emit MessageEvent("Hello World, have a nutty day!");
        mfaAuthorizer = _mfaAuthorizer;
        feeToken = IERC20(_feeToken);
        DOMAIN_SEPARATOR = hash(
            EIP712Domain({name: "Envelope", version: "4.4", chainId: block.chainid, verifyingContract: address(this)})
        );
    }

    function hash(EIP712Domain memory eip712Domain) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(eip712Domain.name)),
                keccak256(bytes(eip712Domain.version)),
                eip712Domain.chainId,
                eip712Domain.verifyingContract
            )
        );
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
    // Deposit Functions
    // ══════════════════════════════════════════════════════════════════════════════

    function makeDeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeDeposit(
            _tokenAddress, _contractType, _amount, _tokenId, _pubKey20, msg.sender, false, address(0), 0, 0, 0, false
        );
    }

    function makeMFADeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeDeposit(
            _tokenAddress, _contractType, _amount, _tokenId, _pubKey20, msg.sender, true, address(0), 0, 0, 0, false
        );
    }

    function makeSelflessMFADeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20,
        address _onBehalfOf
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeDeposit(
            _tokenAddress, _contractType, _amount, _tokenId, _pubKey20, _onBehalfOf, true, address(0), 0, 0, 0, false
        );
    }

    function makeSelflessDeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20,
        address _onBehalfOf
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeDeposit(
            _tokenAddress, _contractType, _amount, _tokenId, _pubKey20, _onBehalfOf, false, address(0), 0, 0, 0, false
        );
    }

    /**
     * @notice The main function that supports all scenarios of depositing.
     * @param _tokenAddress address of the token being sent. 0x0 for eth
     * @param _contractType 0 for eth, 1 for erc20, 2 for erc721, 3 for erc1155
     * @param _amount amount of tokens being sent
     * @param _tokenId id of the token being sent if erc721 or erc1155
     * @param _pubKey20 last 20 bytes of the public key of the deposit signer
     * @param _onBehalfOf who will be able to reclaim the link if the private key is lost
     * @param _withMFA whether an external authorisation is required for withdrawal
     * @param _recipient if not 0x00, only _recipient will be able to withdraw
     * @param _reclaimableAfter if _recipient is set, the sender can reclaim only after this timestamp
     * @return uint256 index of the deposit
     */
    function makeCustomDeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20,
        address _onBehalfOf,
        bool _withMFA,
        address _recipient,
        uint40 _reclaimableAfter
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeDeposit(
            _tokenAddress,
            _contractType,
            _amount,
            _tokenId,
            _pubKey20,
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
     * @notice Create a deposit and collect backend-authorized service/gasless fees up front.
     * @dev Non-zero fees are paid in `feeToken` by msg.sender. `gaslessFee > 0` or
     *      `gaslessSponsored == true` marks the deposit as eligible for EnvelopePaymaster-sponsored
     *      claim or sender reclaim. The fee authorization is signed by `mfaAuthorizer` and includes
     *      the full deposit intent plus a deadline.
     */
    function makeCustomDepositWithFees(DepositRequest calldata _request, FeeAuthorization calldata _feeAuthorization)
        public
        payable
        nonReentrant
        returns (uint256)
    {
        _verifyFeeAuthorization(_request, _feeAuthorization);
        uint256 amount =
            _pullTokensViaApproval(_request.tokenAddress, _request.contractType, _request.amount, _request.tokenId);

        uint256 index = deposits.length;
        _collectDepositFees(index, msg.sender, _feeAuthorization.serviceFee, _feeAuthorization.gaslessFee);

        return _storeDeposit(
            _request.tokenAddress,
            _request.contractType,
            amount,
            _request.tokenId,
            _request.pubKey20,
            _request.onBehalfOf,
            _request.withMFA,
            _request.recipient,
            _request.reclaimableAfter,
            _feeAuthorization.serviceFee,
            _feeAuthorization.gaslessFee,
            _feeAuthorization.gaslessSponsored
        );
    }

    /// @notice Create many same-shape deposits in one transaction.
    /// @dev The caller remains the recorded sender for every deposit and keeps reclaim rights.
    ///      ERC-721 is intentionally excluded here because each NFT needs a distinct tokenId.
    function makeBatchDeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address[] calldata _pubKeys20
    ) external payable nonReentrant returns (uint256[] memory) {
        uint256 totalAmount = _amount * _pubKeys20.length;
        _pullUniformBatchAssets(msg.sender, _tokenAddress, _contractType, totalAmount, _tokenId);

        uint256[] memory depositIndexes = new uint256[](_pubKeys20.length);
        for (uint256 i = 0; i < _pubKeys20.length; ++i) {
            depositIndexes[i] = _storeDeposit(
                _tokenAddress,
                _contractType,
                _amount,
                _tokenId,
                _pubKeys20[i],
                msg.sender,
                false,
                address(0),
                0,
                0,
                0,
                false
            );
        }
        return depositIndexes;
    }

    /// @notice Same as makeBatchDeposit, but avoids allocating and returning the indexes array.
    function makeBatchDepositNoReturn(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address[] calldata _pubKeys20
    ) external payable nonReentrant {
        uint256 totalAmount = _amount * _pubKeys20.length;
        _pullUniformBatchAssets(msg.sender, _tokenAddress, _contractType, totalAmount, _tokenId);

        for (uint256 i = 0; i < _pubKeys20.length; ++i) {
            _storeDeposit(
                _tokenAddress,
                _contractType,
                _amount,
                _tokenId,
                _pubKeys20[i],
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

    /// @notice Create a heterogeneous batch of no-fee deposits.
    /// @dev Supports ETH, ERC-20, ERC-721, and ERC-1155. Recipient binding is intentionally
    ///      left to makeBatchCustomDepositWithFees via DepositRequest[].
    function makeBatchCustomDeposit(
        address[] calldata _tokenAddresses,
        uint8[] calldata _contractTypes,
        uint256[] calldata _amounts,
        uint256[] calldata _tokenIds,
        address[] calldata _pubKeys20,
        bool[] calldata _withMFAs
    ) external payable nonReentrant returns (uint256[] memory) {
        _validateBatchArrayLengths(
            _tokenAddresses.length,
            _contractTypes.length,
            _amounts.length,
            _tokenIds.length,
            _pubKeys20.length,
            _withMFAs.length
        );

        uint256 expectedEther;
        for (uint256 i = 0; i < _amounts.length; ++i) {
            if (_contractTypes[i] > 3) revert InvalidContractType();
            if (_contractTypes[i] == 0) expectedEther += _amounts[i];
        }
        if (msg.value != expectedEther) revert InvalidTotalEtherSent();

        uint256[] memory depositIndexes = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; ++i) {
            uint256 amount = _pullTokensViaApprovalFrom(
                msg.sender,
                _tokenAddresses[i],
                _contractTypes[i],
                _amounts[i],
                _tokenIds[i],
                _contractTypes[i] == 0 ? _amounts[i] : 0
            );
            depositIndexes[i] = _storeDeposit(
                _tokenAddresses[i],
                _contractTypes[i],
                amount,
                _tokenIds[i],
                _pubKeys20[i],
                msg.sender,
                _withMFAs[i],
                address(0),
                0,
                0,
                0,
                false
            );
        }
        return depositIndexes;
    }

    /// @notice Create a heterogeneous batch of deposits with backend-authorized fees.
    /// @dev Fee authorizations are signed for the real caller because batching is vault-native.
    function makeBatchCustomDepositWithFees(
        DepositRequest[] calldata _requests,
        FeeAuthorization[] calldata _feeAuthorizations
    ) external payable nonReentrant returns (uint256[] memory) {
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

        uint256[] memory depositIndexes = new uint256[](_requests.length);
        for (uint256 i = 0; i < _requests.length; ++i) {
            DepositRequest calldata request = _requests[i];
            FeeAuthorization calldata feeAuthorization = _feeAuthorizations[i];
            uint256 amount = _pullTokensViaApprovalFrom(
                msg.sender,
                request.tokenAddress,
                request.contractType,
                request.amount,
                request.tokenId,
                request.contractType == 0 ? request.amount : 0
            );

            uint256 index = deposits.length;
            _collectDepositFees(index, msg.sender, feeAuthorization.serviceFee, feeAuthorization.gaslessFee);
            depositIndexes[i] = _storeDeposit(
                request.tokenAddress,
                request.contractType,
                amount,
                request.tokenId,
                request.pubKey20,
                request.onBehalfOf,
                request.withMFA,
                request.recipient,
                request.reclaimableAfter,
                feeAuthorization.serviceFee,
                feeAuthorization.gaslessFee,
                feeAuthorization.gaslessSponsored
            );
        }

        return depositIndexes;
    }

    /// @notice Create raffle-style ETH or ERC-20 deposits sharing one pubKey20 and different amounts.
    function makeBatchDepositRaffle(
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address _pubKey20
    ) external payable nonReentrant returns (uint256[] memory) {
        return _makeBatchDepositRaffle(_tokenAddress, _contractType, _amounts, _pubKey20, false);
    }

    /// @notice Create MFA-gated raffle-style ETH or ERC-20 deposits sharing one pubKey20.
    function makeBatchMFADepositRaffle(
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address _pubKey20
    ) external payable nonReentrant returns (uint256[] memory) {
        return _makeBatchDepositRaffle(_tokenAddress, _contractType, _amounts, _pubKey20, true);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Withdrawal Functions
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw tokens. Can be called by anyone with a valid signature.
     */
    function withdrawDeposit(uint256 _index, address _recipientAddress, bytes memory _signature)
        external
        nonReentrant
        returns (bool)
    {
        return _withdrawDeposit(_index, _recipientAddress, ANYONE_WITHDRAWAL_MODE, _signature, false);
    }

    /**
     * @notice Withdraw tokens with backend MFA approval.
     * @param _index deposit index
     * @param _recipientAddress address to receive the full deposit amount
     * @param _signature withdrawal signature from the deposit's pubKey20
     * @param _MFASignature backend signature authorizing this withdrawal
     * @param _deadline backend-provided signature deadline; 0 means no expiry
     */
    function withdrawMFADeposit(
        uint256 _index,
        address _recipientAddress,
        bytes memory _signature,
        bytes memory _MFASignature,
        uint256 _deadline
    ) external nonReentrant returns (bool) {
        _verifyMfaSignature(_index, _recipientAddress, _deadline, _MFASignature);
        return _withdrawDeposit(_index, _recipientAddress, ANYONE_WITHDRAWAL_MODE, _signature, true);
    }

    /**
     * @notice Withdraw tokens. Must be called by the recipient.
     */
    function withdrawDepositAsRecipient(uint256 _index, address _recipientAddress, bytes memory _signature)
        external
        nonReentrant
        returns (bool)
    {
        if (_recipientAddress != msg.sender) revert NotTheRecipient();
        return _withdrawDeposit(_index, _recipientAddress, RECIPIENT_WITHDRAWAL_MODE, _signature, false);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Sender Reclaim Functions
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Sender reclaims their deposit directly.
     */
    function withdrawDepositSender(uint256 _index) external nonReentrant returns (bool) {
        return _withdrawDepositSender(_index, msg.sender);
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
    ///      paymaster only pays for prepaid gasless deposits that should execute successfully.
    function isValidGaslessOperation(address caller, bytes calldata callData) external view returns (bool) {
        if (callData.length < 4) return false;

        bytes4 selector = bytes4(callData[0:4]);

        if (selector == this.withdrawDeposit.selector) {
            (uint256 index, address recipient, bytes memory signature) =
                abi.decode(callData[4:], (uint256, address, bytes));
            return _isValidGaslessClaim(caller, index, recipient, ANYONE_WITHDRAWAL_MODE, signature, false);
        }

        if (selector == this.withdrawDepositAsRecipient.selector) {
            (uint256 index, address recipient, bytes memory signature) =
                abi.decode(callData[4:], (uint256, address, bytes));
            return _isValidGaslessClaim(caller, index, recipient, RECIPIENT_WITHDRAWAL_MODE, signature, false);
        }

        if (selector == this.withdrawMFADeposit.selector) {
            (uint256 index, address recipient, bytes memory signature, bytes memory mfaSignature, uint256 deadline) =
                abi.decode(callData[4:], (uint256, address, bytes, bytes, uint256));
            if (!_isMfaSignatureValid(index, recipient, deadline, mfaSignature)) return false;
            return _isValidGaslessClaim(caller, index, recipient, ANYONE_WITHDRAWAL_MODE, signature, true);
        }

        if (selector == this.withdrawDepositSender.selector) {
            (uint256 index) = abi.decode(callData[4:], (uint256));
            return _isValidGaslessReclaim(caller, index);
        }

        return false;
    }

    function getDepositCount() external view returns (uint256) {
        return deposits.length;
    }

    function getDeposit(uint256 _index) external view returns (Deposit memory) {
        return deposits[_index];
    }

    function getAllDeposits() external view returns (Deposit[] memory) {
        return deposits;
    }

    function getAllDepositsForAddress(address _address) external view returns (Deposit[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < deposits.length; ++i) {
            if (deposits[i].senderAddress == _address) {
                count++;
            }
        }
        Deposit[] memory _deposits = new Deposit[](count);
        count = 0;
        for (uint256 i = 0; i < deposits.length; ++i) {
            if (deposits[i].senderAddress == _address) {
                _deposits[count] = deposits[i];
                count++;
            }
        }
        return _deposits;
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
        if (_deadline != 0 && block.timestamp > _deadline) return false;

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(ENVELOPE_SALT, block.chainid, address(this), _index, _recipientAddress, _deadline)
            )
        );
        return _recoverSigner(digest, _signature) == mfaAuthorizer;
    }

    function _verifyFeeAuthorization(DepositRequest calldata _request, FeeAuthorization calldata _feeAuthorization)
        internal
        view
    {
        uint256 totalFee = _feeAuthorization.serviceFee + _feeAuthorization.gaslessFee;
        if (totalFee == 0 && !_feeAuthorization.gaslessSponsored && _feeAuthorization.signature.length == 0) return;
        if (totalFee > 0 && address(feeToken) == address(0)) revert FeeTokenNotConfigured();
        if (_feeAuthorization.deadline != 0 && block.timestamp > _feeAuthorization.deadline) {
            revert FeeAuthorizationExpired();
        }

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encode(
                    ENVELOPE_SALT,
                    block.chainid,
                    address(this),
                    msg.sender,
                    _request.tokenAddress,
                    _request.contractType,
                    _request.amount,
                    _request.tokenId,
                    _request.pubKey20,
                    _request.onBehalfOf,
                    _request.withMFA,
                    _request.recipient,
                    _request.reclaimableAfter,
                    _feeAuthorization.serviceFee,
                    _feeAuthorization.gaslessFee,
                    _feeAuthorization.gaslessSponsored,
                    _feeAuthorization.deadline
                )
            )
        );
        address authorizationSigner = getSigner(digest, _feeAuthorization.signature);
        if (authorizationSigner != mfaAuthorizer) revert WrongFeeAuthorizationSignature();
    }

    function _collectDepositFees(uint256 _index, address _feePayer, uint256 _serviceFee, uint256 _gaslessFee) internal {
        uint256 totalFee = _serviceFee + _gaslessFee;
        if (totalFee > 0) {
            address tokenAddress = address(feeToken);
            feeToken.safeTransferFrom(_feePayer, address(this), totalFee);
            accumulatedFees[tokenAddress] += totalFee;
            emit FeeCollected(_index, tokenAddress, _serviceFee, _gaslessFee);
        }
    }

    function _storeDeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20,
        address _onBehalfOf,
        bool _requiresMFA,
        address _recipient,
        uint40 _reclaimableAfter,
        uint256 _serviceFee,
        uint256 _gaslessFee,
        bool _gaslessSponsored
    ) internal returns (uint256) {
        deposits.push(
            Deposit({
                tokenAddress: _tokenAddress,
                contractType: _contractType,
                amount: _amount,
                tokenId: _tokenId,
                claimed: false,
                pubKey20: _pubKey20,
                senderAddress: _onBehalfOf,
                timestamp: uint40(block.timestamp),
                requiresMFA: _requiresMFA,
                gaslessSponsored: _gaslessSponsored,
                recipient: _recipient,
                reclaimableAfter: _reclaimableAfter,
                serviceFee: _serviceFee,
                gaslessFee: _gaslessFee
            })
        );
        emit DepositEvent(deposits.length - 1, _contractType, _amount, _onBehalfOf);
        return deposits.length - 1;
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
        if (_index >= deposits.length) return false;
        Deposit storage deposit = deposits[_index];
        if (deposit.gaslessFee == 0 && !deposit.gaslessSponsored) return false;
        return _isValidWithdrawal(_index, _recipientAddress, _extraData, _signature, _authorized);
    }

    function _isValidWithdrawal(
        uint256 _index,
        address _recipientAddress,
        bytes32 _extraData,
        bytes memory _signature,
        bool _authorized
    ) internal view returns (bool) {
        Deposit memory deposit = deposits[_index];
        if (deposit.claimed) return false;
        if (deposit.requiresMFA && !_authorized) return false;
        if (deposit.recipient != address(0) && _recipientAddress != deposit.recipient) return false;

        if (deposit.pubKey20 != address(0)) {
            bytes32 recipientAddressHash = MessageHashUtils.toEthSignedMessageHash(
                keccak256(
                    abi.encodePacked(ENVELOPE_SALT, block.chainid, address(this), _index, _recipientAddress, _extraData)
                )
            );
            if (_recoverSigner(recipientAddressHash, _signature) != deposit.pubKey20) return false;
        }

        return true;
    }

    function _isValidGaslessReclaim(address _caller, uint256 _index) internal view returns (bool) {
        if (_index >= deposits.length) return false;
        Deposit memory deposit = deposits[_index];
        if (deposit.gaslessFee == 0 && !deposit.gaslessSponsored) return false;
        if (deposit.claimed) return false;
        if (deposit.senderAddress != _caller) return false;
        if (deposit.recipient != address(0) && block.timestamp <= deposit.reclaimableAfter) return false;
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
        uint256 _pubKeys20Length,
        uint256 _withMFAsLength
    ) internal pure {
        if (
            _tokenAddressesLength != _pubKeys20Length || _contractTypesLength != _pubKeys20Length
                || _amountsLength != _pubKeys20Length || _tokenIdsLength != _pubKeys20Length
                || _withMFAsLength != _pubKeys20Length
        ) revert ParametersLengthMismatch();
    }

    function _pullUniformBatchAssets(
        address _from,
        address _tokenAddress,
        uint8 _contractType,
        uint256 _totalAmount,
        uint256 _tokenId
    ) internal {
        if (_contractType == 0) {
            if (msg.value != _totalAmount) revert InvalidTotalEtherSent();
            return;
        }
        if (msg.value != 0) revert EthNotAcceptedForNonEthDeposit();

        if (_contractType == 1) {
            if (_totalAmount > 0) IERC20(_tokenAddress).safeTransferFrom(_from, address(this), _totalAmount);
        } else if (_contractType == 2) {
            revert Erc721BatchNotSupported();
        } else if (_contractType == 3) {
            if (_totalAmount > 0) {
                IERC1155(_tokenAddress).safeTransferFrom(_from, address(this), _tokenId, _totalAmount, "");
            }
        } else {
            revert InvalidContractType();
        }
    }

    function _makeBatchDepositRaffle(
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address _pubKey20,
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
            if (msg.value != 0) revert EthNotAcceptedForNonEthDeposit();
            if (totalAmount > 0) IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), totalAmount);
        }

        uint256[] memory depositIndexes = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; ++i) {
            depositIndexes[i] = _storeDeposit(
                _tokenAddress,
                _contractType,
                _amounts[i],
                0,
                _pubKey20,
                msg.sender,
                _requiresMFA,
                address(0),
                0,
                0,
                0,
                false
            );
        }
        return depositIndexes;
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
            IERC20(_tokenAddress).safeTransferFrom(_from, address(this), _amount);
        } else if (_contractType == 2) {
            if (_amount != 1) revert Erc721AmountMustBeOne();
            IERC721(_tokenAddress).safeTransferFrom(_from, address(this), _tokenId, "Internal transfer");
        } else if (_contractType == 3) {
            IERC1155(_tokenAddress).safeTransferFrom(_from, address(this), _tokenId, _amount, "Internal transfer");
        }

        return _amount;
    }

    function _withdrawDeposit(
        uint256 _index,
        address _recipientAddress,
        bytes32 _extraData,
        bytes memory _signature,
        bool _authorized
    ) internal returns (bool) {
        if (_index >= deposits.length) revert DepositIndexOutOfBounds();
        Deposit memory _deposit = deposits[_index];
        if (_deposit.claimed) revert DepositAlreadyClaimed();

        address depositSigner;
        if (_signature.length > 0) {
            bytes32 _recipientAddressHash = MessageHashUtils.toEthSignedMessageHash(
                keccak256(
                    abi.encodePacked(ENVELOPE_SALT, block.chainid, address(this), _index, _recipientAddress, _extraData)
                )
            );
            depositSigner = getSigner(_recipientAddressHash, _signature);
        }
        if (_deposit.requiresMFA && !_authorized) revert RequiresMfaAuthorization();
        if (_deposit.pubKey20 != address(0) && depositSigner != _deposit.pubKey20) revert WrongSignature();
        if (_deposit.recipient != address(0) && _recipientAddress != _deposit.recipient) revert WrongRecipient();

        emit WithdrawEvent(_index, _deposit.contractType, _deposit.amount, _recipientAddress);
        deposits[_index].claimed = true;

        if (_deposit.contractType == 0) {
            (bool success,) = _recipientAddress.call{value: _deposit.amount}("");
            if (!success) revert EthTransferFailed();
        } else if (_deposit.contractType == 1) {
            IERC20(_deposit.tokenAddress).safeTransfer(_recipientAddress, _deposit.amount);
        } else if (_deposit.contractType == 2) {
            IERC721(_deposit.tokenAddress).safeTransferFrom(address(this), _recipientAddress, _deposit.tokenId);
        } else if (_deposit.contractType == 3) {
            IERC1155(_deposit.tokenAddress)
                .safeTransferFrom(address(this), _recipientAddress, _deposit.tokenId, _deposit.amount, "");
        }

        return true;
    }

    function _withdrawDepositSender(uint256 _index, address _senderAddress) internal returns (bool) {
        if (_index >= deposits.length) revert DepositIndexOutOfBounds();
        Deposit memory _deposit = deposits[_index];
        if (_deposit.claimed) revert DepositAlreadyClaimed();
        if (_deposit.senderAddress != _senderAddress) revert NotTheSender();
        if (_deposit.recipient != address(0)) {
            if (block.timestamp <= _deposit.reclaimableAfter) revert TooEarlyToReclaim();
        }

        emit WithdrawEvent(_index, _deposit.contractType, _deposit.amount, _deposit.senderAddress);
        deposits[_index].claimed = true;

        if (_deposit.contractType == 0) {
            (bool success,) = payable(_deposit.senderAddress).call{value: _deposit.amount}("");
            if (!success) revert EthTransferFailed();
        } else if (_deposit.contractType == 1) {
            IERC20(_deposit.tokenAddress).safeTransfer(_deposit.senderAddress, _deposit.amount);
        } else if (_deposit.contractType == 2) {
            IERC721(_deposit.tokenAddress).safeTransferFrom(address(this), _deposit.senderAddress, _deposit.tokenId);
        } else if (_deposit.contractType == 3) {
            IERC1155(_deposit.tokenAddress)
                .safeTransferFrom(address(this), _deposit.senderAddress, _deposit.tokenId, _deposit.amount, "");
        }

        return true;
    }
}
