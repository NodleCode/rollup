// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title VestingWallet
 * @notice This contract allows the locking and releasing of tokens over time. A special
 * feature of this contract is that the deployer/owner can revoke the vesting of any
 * address at any time, which would release all the vested tokens to the beneficiary and
 * move the unvested tokens back to the owner.
 */
contract VestingWallet is Ownable {
    IERC20 public immutable token;
    address public immutable beneficiary;
    uint256 public immutable start;
    uint256 public immutable duration;

    error NoTokensAvailable();

    /**
     * @notice Construct a new VestingWallet contract
     * @param _token The token to be vested
     * @param _beneficiary The address that will receive the vested tokens
     * @param _start The timestamp when the vesting starts
     * @param _duration The duration of the vesting in seconds
     */
    constructor(IERC20 _token, address _beneficiary, uint256 _start, uint256 _duration) Ownable(msg.sender) {
        token = _token;
        beneficiary = _beneficiary;
        start = _start;
        duration = _duration;
    }

    function vested() public view returns (uint256) {
        return 0;
    }

    function claimed() public view returns (uint256) {
        return 0;
    }

    function vest() public {
        _mustHaveTokensToVest();
    }

    function _mustHaveTokensToVest() private view {
        if (vested() == claimed()) {
            revert NoTokensAvailable();
        }
    }

    // revoke
}
