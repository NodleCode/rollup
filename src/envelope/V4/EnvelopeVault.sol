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
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPaymaster} from "../util/IPaymaster.sol";

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
    error InvalidGaslessReclaimSignature();
    error EthTransferFailed();
    error DirectTransfersNotAllowed();
    error FeeExceedsDepositAmount();
    error NoFeesToWithdraw();

    // ── Data Structures ──────────────────────────────────────────────────────────

    struct Deposit {
        address pubKey20; // (20 bytes) last 20 bytes of the hash of the public key for the deposit
        uint256 amount; // (32 bytes) amount of the asset being sent
        ///// tokenAddress, contractType, tokenId, claimed & timestamp are stored in a single 32 byte word
        address tokenAddress; // (20 bytes) address of the asset being sent. 0x0 for eth
        uint8 contractType; // (1 byte) 0 for eth, 1 for erc20, 2 for erc721, 3 for erc1155
        bool claimed; // (1 byte) has this deposit been claimed
        bool requiresMFA; // (1 byte) is additional auth (MFA) required?
        uint40 timestamp; // ( 5 bytes) timestamp of the deposit
        /////
        uint256 tokenId; // (32 bytes) id of the token being sent (if erc721 or erc1155)
        address senderAddress; // (20 bytes) address of the sender
        ///// slot for address-bound links data
        address recipient; // unless it's 0x00, only this address can claim the link
        uint40 reclaimableAfter; // for address-bound links, the sender is able to re-claim only after this timestamp
    } // 6 storage slots (32 byte each)

    // We may include this hash in peanut-specific signatures to make sure
    // that the message signed by the user has effects only in peanut contracts.
    bytes32 public constant ENVELOPE_SALT = 0x70adbbeba9d4f0c82e28dd574f15466f75df0543b65f24460fc445813b5d94e0; // keccak256("Konrad makes tokens go woosh tadam");

    bytes32 public constant ANYONE_WITHDRAWAL_MODE = 0x0000000000000000000000000000000000000000000000000000000000000000; // default. Any address can trigger the withdrawal function
    bytes32 public constant RECIPIENT_WITHDRAWAL_MODE = 0x2bb5bef2b248d3edba501ad918c3ab524cce2aea54d4c914414e1c4401dc4ff4; // keccak256("only recipient") - only the signed recipient can trigger the withdrawal function

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

    bytes32 public constant GASLESS_RECLAIM_TYPEHASH = keccak256("GaslessReclaim(uint256 depositIndex)");

    struct GaslessReclaim {
        uint256 depositIndex;
    }

    Deposit[] public deposits; // array of deposits

    /// @notice Accumulated fees per token address (address(0) for ETH).
    mapping(address => uint256) public accumulatedFees;

    // events
    event DepositEvent(
        uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _senderAddress
    );
    event WithdrawEvent(
        uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _recipientAddress
    );
    event FeeCollected(
        uint256 indexed _index, address indexed tokenAddress, uint256 serviceFee, uint256 gasAbsorptionFee
    );
    event FeesWithdrawn(address indexed tokenAddress, uint256 amount);
    event MessageEvent(string message);

    /// @param _mfaAuthorizer address authorized to sign MFA withdraw approvals (use address(0) to disable MFA).
    /// @param _owner initial owner of the contract (receives accumulated fees).
    constructor(address _mfaAuthorizer, address _owner) Ownable(_owner) {
        emit MessageEvent("Hello World, have a nutty day!");
        mfaAuthorizer = _mfaAuthorizer;
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

    function hash(GaslessReclaim memory reclaim) internal pure returns (bytes32) {
        return keccak256(abi.encode(GASLESS_RECLAIM_TYPEHASH, reclaim.depositIndex));
    }

    /**
     * @notice Recover a EIP-712 signed gasless reclaim message
     * @param reclaim the reclaim request
     * @param signer the expected signer of the reclaim request
     * @param signature r-s-v if the signer is an EOA or any random bytes if the signer is a smart contract
     */
    function verifyGaslessReclaim(GaslessReclaim memory reclaim, address signer, bytes memory signature)
        internal
        view
    {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, hash(reclaim)));
        bool valid = SignatureChecker.isValidSignatureNow(signer, digest, signature);
        if (!valid) revert InvalidGaslessReclaimSignature();
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
        return _storeDeposit(_tokenAddress, _contractType, _amount, _tokenId, _pubKey20, msg.sender, false, address(0), 0);
    }

    function makeMFADeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20
    ) public payable nonReentrant returns (uint256) {
        _amount = _pullTokensViaApproval(_tokenAddress, _contractType, _amount, _tokenId);
        return _storeDeposit(_tokenAddress, _contractType, _amount, _tokenId, _pubKey20, msg.sender, true, address(0), 0);
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
        return _storeDeposit(_tokenAddress, _contractType, _amount, _tokenId, _pubKey20, _onBehalfOf, true, address(0), 0);
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
        return _storeDeposit(_tokenAddress, _contractType, _amount, _tokenId, _pubKey20, _onBehalfOf, false, address(0), 0);
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
            _tokenAddress, _contractType, _amount, _tokenId,
            _pubKey20, _onBehalfOf, _withMFA, _recipient, _reclaimableAfter
        );
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Withdrawal Functions
    // ══════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw tokens. Can be called by anyone with a valid signature.
     */
    function withdrawDeposit(
        uint256 _index,
        address _recipientAddress,
        bytes memory _signature
    ) external nonReentrant returns (bool) {
        return _withdrawDeposit(_index, _recipientAddress, ANYONE_WITHDRAWAL_MODE, _signature, false);
    }

    /**
     * @notice Withdraw tokens with MFA. Fees are backend-signed flat amounts.
     * @param _index deposit index
     * @param _recipientAddress address to receive the deposit (minus fees)
     * @param _signature withdrawal signature from the deposit's pubKey20
     * @param _MFASignature backend signature authorizing this withdrawal and specifying fees
     * @param _serviceFee flat fee for the MFA service
     * @param _gasAbsorptionFee flat fee to cover gasless claim; 0 if not absorbing
     */
    function withdrawMFADeposit(
        uint256 _index,
        address _recipientAddress,
        bytes memory _signature,
        bytes memory _MFASignature,
        uint256 _serviceFee,
        uint256 _gasAbsorptionFee
    ) external nonReentrant returns (bool) {
        _verifyMfaSignature(_index, _recipientAddress, _serviceFee, _gasAbsorptionFee, _MFASignature);
        _collectFees(_index, _serviceFee, _gasAbsorptionFee);
        return _withdrawDeposit(_index, _recipientAddress, ANYONE_WITHDRAWAL_MODE, _signature, true);
    }

    /**
     * @notice Sponsored MFA withdrawal. A paymaster submits on behalf of the recipient.
     *         The gasAbsorptionFee is sent to the treasury instead of accumulating.
     * @param _index deposit index
     * @param _recipientAddress address to receive the deposit (minus fees)
     * @param _signature withdrawal signature from the deposit's pubKey20
     * @param _MFASignature backend signature authorizing this withdrawal and specifying fees
     * @param _serviceFee flat fee for the MFA service (accumulated for owner)
     * @param _gasAbsorptionFee flat fee sent to treasury to reimburse gas
     * @param _treasury paymaster address that submitted the tx and receives gasAbsorptionFee
     */
    function withdrawMFADepositSponsored(
        uint256 _index,
        address _recipientAddress,
        bytes memory _signature,
        bytes memory _MFASignature,
        uint256 _serviceFee,
        uint256 _gasAbsorptionFee,
        address _treasury
    ) external nonReentrant returns (bool) {
        _verifyMfaSignature(_index, _recipientAddress, _serviceFee, _gasAbsorptionFee, _MFASignature);

        // Treasury validates the sponsorship
        IPaymaster(_treasury).validateSponsoredOperation(msg.sender, _gasAbsorptionFee);

        // Deduct fees: serviceFee → accumulated, gasAbsorptionFee → treasury
        uint256 totalFee = _serviceFee + _gasAbsorptionFee;
        if (totalFee > 0) {
            Deposit storage dep = deposits[_index];
            if (totalFee > dep.amount) revert FeeExceedsDepositAmount();
            dep.amount -= totalFee;

            if (_serviceFee > 0) {
                accumulatedFees[dep.tokenAddress] += _serviceFee;
            }
            if (_gasAbsorptionFee > 0) {
                _transferFeeToTreasury(dep.tokenAddress, _gasAbsorptionFee, _treasury);
            }
            emit FeeCollected(_index, dep.tokenAddress, _serviceFee, _gasAbsorptionFee);
        }

        return _withdrawDeposit(_index, _recipientAddress, ANYONE_WITHDRAWAL_MODE, _signature, true);
    }

    /**
     * @notice Withdraw tokens. Must be called by the recipient.
     */
    function withdrawDepositAsRecipient(
        uint256 _index,
        address _recipientAddress,
        bytes memory _signature
    ) external nonReentrant returns (bool) {
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

    /**
     * @notice Sponsored sender reclaim. A paymaster submits on behalf of the sender.
     *         Sender authorizes via EIP-712 signature. MFA authorizer signs the gas fee.
     * @param _reclaim EIP-712 signed reclaim request
     * @param _signer the sender address (must match deposit's senderAddress)
     * @param _signature EIP-712 signature from the sender authorizing reclaim
     * @param _MFASignature backend signature specifying the gas absorption fee
     * @param _gasAbsorptionFee flat fee sent to treasury to reimburse gas
     * @param _treasury paymaster address that receives gasAbsorptionFee
     */
    function withdrawDepositSenderSponsored(
        GaslessReclaim calldata _reclaim,
        address _signer,
        bytes calldata _signature,
        bytes calldata _MFASignature,
        uint256 _gasAbsorptionFee,
        address _treasury
    ) external nonReentrant returns (bool) {
        // Verify sender authorized this reclaim
        verifyGaslessReclaim(_reclaim, _signer, _signature);

        // Verify MFA signature covers the fee for this sponsored reclaim
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    ENVELOPE_SALT,
                    block.chainid,
                    address(this),
                    _reclaim.depositIndex,
                    _signer,
                    _gasAbsorptionFee
                )
            )
        );
        address authorizationSigner = getSigner(digest, _MFASignature);
        if (authorizationSigner != mfaAuthorizer) revert WrongMfaSignature();

        // Treasury validates
        IPaymaster(_treasury).validateSponsoredOperation(msg.sender, _gasAbsorptionFee);

        // Deduct gas fee from deposit and send to treasury
        if (_gasAbsorptionFee > 0) {
            Deposit storage dep = deposits[_reclaim.depositIndex];
            if (_gasAbsorptionFee > dep.amount) revert FeeExceedsDepositAmount();
            dep.amount -= _gasAbsorptionFee;
            _transferFeeToTreasury(dep.tokenAddress, _gasAbsorptionFee, _treasury);
            emit FeeCollected(_reclaim.depositIndex, dep.tokenAddress, 0, _gasAbsorptionFee);
        }

        return _withdrawDepositSender(_reclaim.depositIndex, _signer);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // Token Receiver Hooks
    // ══════════════════════════════════════════════════════════════════════════════

    function onERC721Received(address _operator, address, uint256, bytes calldata)
        external view override returns (bytes4)
    {
        if (_operator != address(this)) revert DirectTransfersNotAllowed();
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address _operator, address, uint256, uint256, bytes calldata)
        external view override returns (bytes4)
    {
        if (_operator != address(this)) revert DirectTransfersNotAllowed();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address _operator, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external view override returns (bytes4)
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
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].senderAddress == _address) {
                count++;
            }
        }
        Deposit[] memory _deposits = new Deposit[](count);
        count = 0;
        for (uint256 i = 0; i < deposits.length; i++) {
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
        uint256 _serviceFee,
        uint256 _gasAbsorptionFee,
        bytes memory _MFASignature
    ) internal view {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(
                abi.encodePacked(
                    ENVELOPE_SALT,
                    block.chainid,
                    address(this),
                    _index,
                    _recipientAddress,
                    _serviceFee,
                    _gasAbsorptionFee
                )
            )
        );
        address authorizationSigner = getSigner(digest, _MFASignature);
        if (authorizationSigner != mfaAuthorizer) revert WrongMfaSignature();
    }

    function _collectFees(uint256 _index, uint256 _serviceFee, uint256 _gasAbsorptionFee) internal {
        uint256 totalFee = _serviceFee + _gasAbsorptionFee;
        if (totalFee > 0) {
            Deposit storage dep = deposits[_index];
            if (totalFee > dep.amount) revert FeeExceedsDepositAmount();
            dep.amount -= totalFee;
            accumulatedFees[dep.tokenAddress] += totalFee;
            emit FeeCollected(_index, dep.tokenAddress, _serviceFee, _gasAbsorptionFee);
        }
    }

    function _transferFeeToTreasury(address _tokenAddress, uint256 _amount, address _treasury) internal {
        if (_tokenAddress == address(0)) {
            (bool success,) = _treasury.call{value: _amount}("");
            if (!success) revert EthTransferFailed();
        } else {
            IERC20(_tokenAddress).safeTransfer(_treasury, _amount);
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
        uint40 _reclaimableAfter
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
                recipient: _recipient,
                reclaimableAfter: _reclaimableAfter
            })
        );
        emit DepositEvent(deposits.length - 1, _contractType, _amount, _onBehalfOf);
        return deposits.length - 1;
    }

    function _pullTokensViaApproval(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId
    ) internal returns (uint256) {
        if (_contractType > 3) revert InvalidContractType();

        if (_contractType == 0) {
            if (_amount != msg.value) revert WrongEthAmount();
        } else if (_contractType == 1) {
            IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        } else if (_contractType == 2) {
            if (_amount != 1) revert Erc721AmountMustBeOne();
            IERC721(_tokenAddress).safeTransferFrom(msg.sender, address(this), _tokenId, "Internal transfer");
        } else if (_contractType == 3) {
            IERC1155(_tokenAddress).safeTransferFrom(msg.sender, address(this), _tokenId, _amount, "Internal transfer");
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
                    abi.encodePacked(
                        ENVELOPE_SALT,
                        block.chainid,
                        address(this),
                        _index,
                        _recipientAddress,
                        _extraData
                    )
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
            IERC1155(_deposit.tokenAddress).safeTransferFrom(address(this), _recipientAddress, _deposit.tokenId, _deposit.amount, "");
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
            IERC1155(_deposit.tokenAddress).safeTransferFrom(address(this), _deposit.senderAddress, _deposit.tokenId, _deposit.amount, "");
        }

        return true;
    }
}
