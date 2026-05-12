/**
 * SPDX-License-Identifier: MIT
 *
 * Copyright (c) 2018-2020 CENTRE SECZ
 */

pragma solidity ^0.8.23;

import {EIP712Domain} from "./EIP712Domain.sol";
import {EIP712} from "./EIP712.sol";
import {IEIP3009} from "./IEIP3009.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract EIP3009Internals is EIP712Domain, ERC20 {
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    mapping(address => mapping(bytes32 => bool)) private _authorizationStates;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    function _transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        _requireValidAuthorization(from, nonce, validAfter, validBefore);

        bytes memory data =
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce);
        require(EIP712.recover(DOMAIN_SEPARATOR, v, r, s, data) == from, "FiatTokenV2: invalid signature");

        _markAuthorizationAsUsed(from, nonce);
        _transfer(from, to, value);
    }

    function _receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        require(to == msg.sender, "FiatTokenV2: caller must be the payee");
        _requireValidAuthorization(from, nonce, validAfter, validBefore);

        bytes memory data =
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce);
        require(EIP712.recover(DOMAIN_SEPARATOR, v, r, s, data) == from, "FiatTokenV2: invalid signature");

        _markAuthorizationAsUsed(from, nonce);
        _transfer(from, to, value);
    }

    function _cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) internal {
        _requireUnusedAuthorization(authorizer, nonce);

        bytes memory data = abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce);
        require(EIP712.recover(DOMAIN_SEPARATOR, v, r, s, data) == authorizer, "FiatTokenV2: invalid signature");

        _authorizationStates[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    function _requireUnusedAuthorization(address authorizer, bytes32 nonce) private view {
        require(!_authorizationStates[authorizer][nonce], "FiatTokenV2: authorization is used or canceled");
    }

    function _requireValidAuthorization(address authorizer, bytes32 nonce, uint256 validAfter, uint256 validBefore)
        private
        view
    {
        require(block.timestamp > validAfter, "FiatTokenV2: authorization is not yet valid");
        require(block.timestamp < validBefore, "FiatTokenV2: authorization is expired");
        _requireUnusedAuthorization(authorizer, nonce);
    }

    function _markAuthorizationAsUsed(address authorizer, bytes32 nonce) private {
        _authorizationStates[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }
}
