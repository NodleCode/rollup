// SPDX-License-Identifier: GPL-3.0-or-later
//
// Modified by Nodle (2026-05-12) — see src/envelope/doc/EnvelopeBatcher.md ("Vendoring
// patches") and the git history of this file for the full patch set. The upstream source
// is peanutprotocol/vault-contracts@main; the full GNU GPL v3 license text is bundled
// at src/envelope/V4/LICENSE-GPL.
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EnvelopeVault} from "./PeanutV4.4.sol";

/// @title  Peanut Batcher V4.4
/// @notice Stateless helper that pulls tokens from msg.sender then forwards N deposits
///         to a target EnvelopeVault vault.
/// @dev    Holds no persistent state — the EnvelopeVault reference is taken per call so the
///         contract can fan out to multiple vaults and so EraVM doesn't charge pubdata
///         for storage writes on the hot path.
contract EnvelopeBatcher is IERC721Receiver, IERC1155Receiver {
    using SafeERC20 for IERC20;

    function _setAllowanceIfZero(address tokenAddress, address spender) internal {
        uint256 currentAllowance = IERC20(tokenAddress).allowance(address(this), spender);
        if (currentAllowance == 0) {
            IERC20(tokenAddress).forceApprove(spender, type(uint256).max);
        }
    }

    function supportsInterface(bytes4 _interfaceId) external pure override(IERC165) returns (bool) {
        return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC721Receiver).interfaceId
            || _interfaceId == type(IERC1155Receiver).interfaceId;
    }

    /// @notice ERC-721 receiver hook. Self-only — unsolicited transfers revert (S1).
    function onERC721Received(address _operator, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        require(_operator == address(this), "DIRECT TRANSFERS NOT ALLOWED");
        return this.onERC721Received.selector;
    }

    /// @notice ERC-1155 receiver hook. Self-only — unsolicited transfers revert (S1).
    function onERC1155Received(address _operator, address, uint256, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        require(_operator == address(this), "DIRECT TRANSFERS NOT ALLOWED");
        return this.onERC1155Received.selector;
    }

    /// @notice ERC-1155 batch receiver hook. Self-only — unsolicited transfers revert (S1).
    function onERC1155BatchReceived(
        address _operator,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        require(_operator == address(this), "DIRECT TRANSFERS NOT ALLOWED");
        return this.onERC1155BatchReceived.selector;
    }

    function batchMakeDeposit(
        address _vaultAddress,
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address[] calldata _pubKeys20
    ) external payable returns (uint256[] memory) {
        EnvelopeVault vault = EnvelopeVault(_vaultAddress);
        uint256 totalAmount = _amount * _pubKeys20.length;
        uint256 etherAmount;

        if (_contractType == 0) {
            require(msg.value == totalAmount, "INVALID TOTAL ETHER SENT");
            etherAmount = _amount;
        } else if (_contractType == 1) {
            IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), totalAmount);
            _setAllowanceIfZero(_tokenAddress, address(vault));
        } else if (_contractType == 2) {
            revert("ERC721 batch not implemented");
        } else if (_contractType == 3) {
            IERC1155(_tokenAddress).safeTransferFrom(msg.sender, address(this), _tokenId, totalAmount, "");
            IERC1155(_tokenAddress).setApprovalForAll(address(vault), true);
        }

        uint256[] memory depositIndexes = new uint256[](_pubKeys20.length);
        for (uint256 i = 0; i < _pubKeys20.length; i++) {
            depositIndexes[i] = vault.makeSelflessDeposit{value: etherAmount}(
                _tokenAddress, _contractType, _amount, _tokenId, _pubKeys20[i], msg.sender
            );
        }
        return depositIndexes;
    }

    /// @notice Variant of batchMakeDeposit that does not allocate the return array.
    /// @dev Assumes all deposits are the same; uses msg.value as etherAmount per call
    ///      (only meaningful when called with a single deposit, or when sending only ETH dust).
    function batchMakeDepositNoReturn(
        address _vaultAddress,
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address[] calldata _pubKeys20
    ) external payable {
        EnvelopeVault vault = EnvelopeVault(_vaultAddress);
        // For ETH (contractType == 0), the batcher only receives msg.value once; forwarding
        // {value: msg.value} per loop iteration would revert on iteration 2 with insufficient
        // balance. Either require msg.value == _amount * N and forward _amount per call, or
        // for non-ETH paths require msg.value == 0 (no stuck dust in the vault).
        uint256 etherPerCall;
        if (_contractType == 0) {
            require(msg.value == _amount * _pubKeys20.length, "INVALID TOTAL ETHER SENT");
            etherPerCall = _amount;
        } else {
            require(msg.value == 0, "ETH NOT ACCEPTED FOR NON-ETH DEPOSIT");
            etherPerCall = 0;
        }

        for (uint256 i = 0; i < _pubKeys20.length; i++) {
            vault.makeSelflessDeposit{value: etherPerCall}(
                _tokenAddress, _contractType, _amount, _tokenId, _pubKeys20[i], msg.sender
            );
        }
    }

    function batchMakeDepositArbitrary(
        address _vaultAddress,
        address[] memory _tokenAddresses,
        uint8[] memory _contractTypes,
        uint256[] memory _amounts,
        uint256[] memory _tokenIds,
        address[] memory _pubKeys20,
        bool[] memory _withMFAs
    ) external payable returns (uint256[] memory) {
        require(
            _tokenAddresses.length == _pubKeys20.length && _contractTypes.length == _pubKeys20.length
                && _amounts.length == _pubKeys20.length && _tokenIds.length == _pubKeys20.length
                && _withMFAs.length == _pubKeys20.length,
            "PARAMETERS LENGTH MISMATCH"
        );
        EnvelopeVault vault = EnvelopeVault(_vaultAddress);

        uint256[] memory depositIndexes = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; i++) {
            uint256 etherAmount;

            if (_contractTypes[i] == 0) {
                etherAmount = _amounts[i];
            } else if (_contractTypes[i] == 1) {
                IERC20(_tokenAddresses[i]).safeTransferFrom(msg.sender, address(this), _amounts[i]);
                _setAllowanceIfZero(_tokenAddresses[i], _vaultAddress);
            } else if (_contractTypes[i] == 2) {
                revert("ERC721 batch not implemented");
            } else if (_contractTypes[i] == 3) {
                IERC1155(_tokenAddresses[i]).safeTransferFrom(msg.sender, address(this), _tokenIds[i], _amounts[i], "");
                IERC1155(_tokenAddresses[i]).setApprovalForAll(_vaultAddress, true);
            }

            depositIndexes[i] = vault.makeCustomDeposit{value: etherAmount}(
                _tokenAddresses[i],
                _contractTypes[i],
                _amounts[i],
                _tokenIds[i],
                _pubKeys20[i],
                msg.sender, // deposit owner
                _withMFAs[i],
                address(0), // not recipient-bound
                uint40(0),
                false, // not EIP-3009
                "" // not EIP-3009
            );
        }
        return depositIndexes;
    }

    function batchMakeDepositRaffle(
        address _vaultAddress,
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address _pubKey20
    ) external payable returns (uint256[] memory) {
        require(_contractType == 0 || _contractType == 1, "ONLY ETH AND ERC20 RAFFLES ARE SUPPORTED");
        EnvelopeVault vault = EnvelopeVault(_vaultAddress);

        if (_contractType == 1) {
            _setAllowanceIfZero(_tokenAddress, _vaultAddress);
            uint256 totalAmount;
            for (uint256 i = 0; i < _amounts.length; i++) {
                totalAmount += _amounts[i];
            }
            IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), totalAmount);
        }

        uint256[] memory depositIndexes = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; i++) {
            uint256 etherAmount;
            if (_contractType == 0) {
                etherAmount = _amounts[i];
            }
            depositIndexes[i] = vault.makeSelflessDeposit{value: etherAmount}(
                _tokenAddress, _contractType, _amounts[i], 0, _pubKey20, msg.sender
            );
        }
        return depositIndexes;
    }

    function batchMakeDepositRaffleMFA(
        address _vaultAddress,
        address _tokenAddress,
        uint8 _contractType,
        uint256[] calldata _amounts,
        address _pubKey20
    ) external payable returns (uint256[] memory) {
        require(_contractType == 0 || _contractType == 1, "ONLY ETH AND ERC20 RAFFLES ARE SUPPORTED");
        EnvelopeVault vault = EnvelopeVault(_vaultAddress);

        if (_contractType == 1) {
            _setAllowanceIfZero(_tokenAddress, _vaultAddress);
            uint256 totalAmount;
            for (uint256 i = 0; i < _amounts.length; i++) {
                totalAmount += _amounts[i];
            }
            IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), totalAmount);
        }

        uint256[] memory depositIndexes = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; i++) {
            uint256 etherAmount;
            if (_contractType == 0) {
                etherAmount = _amounts[i];
            }
            depositIndexes[i] = vault.makeSelflessMFADeposit{value: etherAmount}(
                _tokenAddress, _contractType, _amounts[i], 0, _pubKey20, msg.sender
            );
        }
        return depositIndexes;
    }
}
