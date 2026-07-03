// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {NODL} from "../NODL.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {L2_MESSENGER} from "lib/era-contracts/l2-contracts/contracts/L2ContractHelper.sol";
import {AddressAliasHelper} from "lib/era-contracts/l1-contracts/contracts/vendor/AddressAliasHelper.sol";
import {IWithdrawalMessage} from "./interfaces/IWithdrawalMessage.sol";

/**
 * @title L2Bridge
 * @notice L2 endpoint of the NODL token bridge for zkSync Era.
 * @dev Mints tokens on finalized deposits from L1 and burns tokens on withdrawals to L1.
 *      Secured with Ownable admin and Pausable circuit breaker.
 */
contract L2Bridge is Ownable2Step, Pausable, IL2Bridge {
    // =====================================
    // State variables
    // =====================================

    /// @notice The NODL token instance on L2.
    NODL public immutable L2_NODL;

    /// @notice The L1 counterpart bridge address.
    address public l1Bridge;

    // =====================================
    // Errors
    // =====================================

    /// @dev Zero address supplied where non-zero is required.
    error ZeroAddress();
    /// @dev Amount must be greater than zero.
    error ZeroAmount();
    /// @dev Unauthorized caller for restricted functions.
    error Unauthorized(address caller);
    /// @dev Owner can only initialize the bridge once.
    error AlreadyInitialized();

    // =====================================
    // Modifiers
    // =====================================

    /// @dev Restricts calls to the aliased L1 bridge system sender.
    modifier onlyL1Bridge() {
        if (msg.sender != AddressAliasHelper.applyL1ToL2Alias(l1Bridge)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    // =====================================
    // Constructor
    // =====================================

    /**
     * @notice Sets up the bridge with the addresses of its L1 counterpart and the L2 token.
     * @param _owner The admin address for Ownable controls.
     * @param _l2Token The L2 NODL token contract address.
     */
    constructor(address _owner, address _l2Token) Ownable(_owner) {
        if (_l2Token == address(0)) {
            revert ZeroAddress();
        }
        l1Bridge = address(0);
        L2_NODL = NODL(_l2Token);
    }

    // =====================================
    // Admin
    // =====================================

    /// @notice Pause state-changing entrypoints guarded by whenNotPaused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract to resume normal operations.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =====================================
    // Bridge entrypoints
    // =====================================
    function initialize(address _l1Bridge) external onlyOwner {
        if (_l1Bridge == address(0)) {
            revert ZeroAddress();
        }
        if (l1Bridge != address(0)) {
            revert AlreadyInitialized();
        }
        l1Bridge = _l1Bridge;
    }

    /**
     * @inheritdoc IL2Bridge
     */
    function finalizeDeposit(address _l1Sender, address _l2Receiver, uint256 _amount)
        external
        override
        onlyL1Bridge
        whenNotPaused
    {
        if (_l1Sender == address(0) || _l2Receiver == address(0)) {
            revert ZeroAddress();
        }
        if (_amount == 0) {
            revert ZeroAmount();
        }

        L2_NODL.mint(_l2Receiver, _amount);

        emit DepositFinalized(_l1Sender, _l2Receiver, _amount);
    }

    /**
     * @inheritdoc IL2Bridge
     */
    function withdraw(address _l1Receiver, uint256 _amount) external override whenNotPaused {
        if (_l1Receiver == address(0)) {
            revert ZeroAddress();
        }
        if (_amount == 0) {
            revert ZeroAmount();
        }

        L2_NODL.burnFrom(msg.sender, _amount);

        // Message schema: 56 bytes = selector (4) + receiver (20) + amount (32)
        bytes memory message = abi.encodePacked(IWithdrawalMessage.finalizeWithdrawal.selector, _l1Receiver, _amount);
        L2_MESSENGER.sendToL1(message);

        emit WithdrawalInitiated(msg.sender, _l1Receiver, _amount);
    }
}
