// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BasePaymaster} from "./BasePaymaster.sol";

contract Erc20Paymaster is BasePaymaster {
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");

    uint256 public feePrice;
    address public allowedToken;

    error AllowanceNotEnough(uint256 provided, uint256 required);
    error FeeTransferFailed(bytes reason);

    constructor(address admin, address priceOracle, address erc20, uint256 initialFeePrice) BasePaymaster(admin, admin) {
        _grantRole(PRICE_ORACLE_ROLE, priceOracle);
        allowedToken = erc20;
        feePrice = initialFeePrice;
    }

    function updatePriceOracle(address priceOracle) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PRICE_ORACLE_ROLE, priceOracle);
    }

    function updateFeePrice(uint256 newFeePrice) public onlyRole(PRICE_ORACLE_ROLE) {
        feePrice = newFeePrice;
    }

    function _validateAndPayGeneralFlow(
        address /* from */,
        address /* to */,
        uint256 /* requiredETH */
    ) internal pure override {
        revert PaymasterFlowNotSupported();
    }

    function _validateAndPayApprovalBasedFlow(
        address userAddress,
        address /* destAddress */,
        address token,
        uint256 /* amount */,
        bytes memory /* data */,
        uint256 requiredETH
    ) internal override {
            address thisAddress = address(this);

            uint256 providedAllowance = IERC20(token).allowance(
                userAddress,
                thisAddress
            );
            uint256 requiredToken = requiredETH * feePrice;

            if (providedAllowance < requiredToken) {
                revert AllowanceNotEnough(providedAllowance, requiredToken);
            }

            try 
                IERC20(token).transferFrom(userAddress, thisAddress, requiredToken)
            {
                return;
            } catch (bytes memory revertReason) {
                revert FeeTransferFailed(revertReason);
            }
    }
}
