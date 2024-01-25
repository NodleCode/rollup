// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BasePaymaster.sol";

contract Erc20Paymaster is BasePaymaster {
    bytes32 public constant PRICE_ORACLE_ROLE = keccak256("PRICE_ORACLE_ROLE");

    uint256 public feePrice;

    address public allowedToken;

    constructor(address _admin, address _price_oracle, address _erc20, uint256 _feePrice) BasePaymaster(_admin, _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PRICE_ORACLE_ROLE, _price_oracle);
        allowedToken = _erc20;
        feePrice = _feePrice;
    }

    function updatePriceOracle(address _price_oracle) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PRICE_ORACLE_ROLE, _price_oracle);
    }

    function updateFeePrice(uint256 _feePrice) public onlyRole(PRICE_ORACLE_ROLE) {
        feePrice = _feePrice;
    }

    function _validateAndPayGeneralFlow(
        address /* from */,
        address /* to */,
        uint256
    ) internal pure override {
        revert PaymasterFlowNotSupported();
    }

    function _validateAndPayApprovalBasedFlow(
        address userAddress,
        address /* destAddress */,
        address token,
        uint256 minAllowance,
        bytes memory /* data*/,
        uint256 requiredETH
    ) internal override {
            address thisAddress = address(this);

            uint256 providedAllowance = IERC20(token).allowance(
                userAddress,
                thisAddress
            );

            require(
                providedAllowance >= minAllowance,
                "Provided allowance lower than minimum"
            );

            uint256 requiredToken = requiredETH * feePrice;

            require(
                providedAllowance >= requiredToken,
                "Provided allowance not covering gas fee"
            );

            try
                IERC20(token).transferFrom(userAddress, thisAddress, requiredToken)
            {} catch (bytes memory revertReason) {
                // If the revert reason is empty or represented by just a function selector,
                // we replace the error with a more user-friendly message
                if (revertReason.length <= 4) {
                    revert("Failed to transferFrom from users' account");
                } else {
                    assembly {
                        revert(add(0x20, revertReason), mload(revertReason))
                    }
                }
            }
    }
}
