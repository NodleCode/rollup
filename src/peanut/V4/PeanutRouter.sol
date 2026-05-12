// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

//////////////////////////////////////////////////////////////////////////////////////
// @title   Peanut Router
// @notice  Bridges a Peanut V4 deposit to another chain via the Squid router.
// @version 0.2.0
// @author  Squirrel Labs (vendored + modernized for nodle/rollup)
//////////////////////////////////////////////////////////////////////////////////////

import {PeanutV4} from "./PeanutV4.4.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract PeanutV4Router is Ownable2Step {
    using SafeERC20 for IERC20;

    address public squidAddress;

    /// @param _squidAddress target Squid router address to forward bridged value to.
    constructor(address _squidAddress) Ownable(msg.sender) {
        squidAddress = _squidAddress;
    }

    /// @notice Withdraw a Peanut deposit and bridge it cross-chain via Squid.
    /// @dev    Validates the EIP-191 v0x00 routing signature first to prevent front-running:
    ///         the relayer is constrained to exactly the squidFee/peanutFee/squidData the
    ///         deposit owner signed off-chain.
    /// @param _peanutAddress       peanut vault to withdraw the deposit from.
    /// @param _depositIndex        index of the deposit in the peanut vault.
    /// @param _withdrawalSignature signature authorizing the peanut withdrawal.
    /// @param _squidFee            squid router fee (must equal msg.value).
    /// @param _peanutFee           fee retained by this router (must be < deposit.amount).
    /// @param _squidData           calldata blob forwarded to the squid router.
    /// @param _routingSignature    signature over (squidFee, peanutFee, squidData), signed by deposit.pubKey20.
    function withdrawAndBridge(
        address _peanutAddress,
        uint256 _depositIndex,
        bytes calldata _withdrawalSignature,
        uint256 _squidFee,
        uint256 _peanutFee,
        bytes calldata _squidData,
        bytes calldata _routingSignature
    ) public payable {
        PeanutV4 peanut = PeanutV4(_peanutAddress);
        PeanutV4.Deposit memory deposit = peanut.getDeposit(_depositIndex);

        // Validate routingSignature (EIP-191 v0x00).
        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes2(0x1900),
                address(this),
                block.chainid,
                _peanutAddress,
                _depositIndex,
                squidAddress,
                _squidFee,
                _peanutFee,
                _squidData
            )
        );
        address routingSigner = ECDSA.recover(digest, _routingSignature);
        require(routingSigner == deposit.pubKey20, "WRONG ROUTING SIGNER");

        require(_squidFee == msg.value, "msg.value MUST BE THE SQUID FEE");
        require(
            deposit.contractType == 0 || deposit.contractType == 1, "X-CHAIN CLAIMS WORK ONLY FOR ETH AND ERC20 TOKENS"
        );
        require(_peanutFee < deposit.amount, "TOO HIGH FEE");

        peanut.withdrawDepositAsRecipient(_depositIndex, address(this), _withdrawalSignature);

        uint256 amountToBridge = deposit.amount - _peanutFee;
        uint256 ethAmountToSquid = msg.value;
        if (deposit.contractType == 0) {
            // ETH deposit
            ethAmountToSquid += amountToBridge;
        } else if (deposit.contractType == 1) {
            // ERC20 deposit
            IERC20(deposit.tokenAddress).safeIncreaseAllowance(squidAddress, amountToBridge);
        } else {
            revert("UNSUPPORTED contractType");
        }

        (bool success,) = payable(squidAddress).call{value: ethAmountToSquid}(_squidData);
        require(success, "FAILED TO INITIATE SQUID TRANSFER");
    }

    /// @notice Withdraw collected fees. Owner-gated (Ownable2Step — handoff requires acceptance).
    /// @param token address(0) for ETH, ERC20 contract otherwise.
    /// @param to    recipient of the fees.
    /// @param amount amount to withdraw.
    function withdrawFees(address token, address to, uint256 amount) public onlyOwner {
        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "FAILED TO WITHDRAW ETH");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {} // allow ETH transfers from peanut vault
}
