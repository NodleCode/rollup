// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {BaseContentSign} from "./BaseContentSign.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PaymentMiddleware is Ownable {
    using SafeERC20 for IERC20;

    error UserNotWhitelisted(address user);

    BaseContentSign public target;
    IERC721 public whitelist;
    IERC20 public feeToken;
    uint256 public feeAmount;

    constructor(BaseContentSign _target, IERC721 _whitelist, IERC20 _feeToken, uint256 _feeAmount, address _admin)
        Ownable(_admin)
    {
        target = _target;
        whitelist = _whitelist;
        feeToken = _feeToken;
        feeAmount = _feeAmount;
    }

    function safeMint(address to, string memory uri) external {
        // Check if user has a whitelist token
        if (whitelist.balanceOf(msg.sender) == 0) {
            revert UserNotWhitelisted(msg.sender);
        }

        // Collect fee
        feeToken.safeTransferFrom(msg.sender, address(this), feeAmount);

        // Mint the token
        target.safeMint(to, uri);
    }

    function withdraw(IERC20 token) external {
        _checkOwner();

        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(owner(), balance);
    }

    function setFeeAmount(uint256 _feeAmount) external {
        _checkOwner();

        feeAmount = _feeAmount;
    }

    function setTarget(BaseContentSign _target) external {
        _checkOwner();

        target = _target;
    }

    function setWhitelist(IERC721 _whitelist) external {
        _checkOwner();

        whitelist = _whitelist;
    }

    function setFeeToken(IERC20 _feeToken) external {
        _checkOwner();

        feeToken = _feeToken;
    }
}
