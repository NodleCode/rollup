// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

interface IPaymasterTest {
    function register(address to, string memory name) external;
}

contract PaymasterTest is IPaymasterTest {
    mapping(uint256 => address) public ownerOf;

    event NameRegistered(string indexed name, address indexed owner);

    /// @notice Thrown when attempting to register a name that is not alphanumeric
    error NameMustBeAlphanumeric();

    /// @notice Thrown when attempting to register a name that is empty
    error NameCannotBeEmpty();

    /// @notice Thrown when attempting to register a name that already exists
    /// @param owner The address of the current owner of the name
    error NameAlreadyExists(address owner);

    function register(address to, string memory name) public override {
        if (bytes(name).length == 0) {
            revert NameCannotBeEmpty();
        }
        if (!_isAlphanumeric(name)) {
            revert NameMustBeAlphanumeric();
        }

        uint256 tokenId = uint256(keccak256(abi.encodePacked(name)));
        address owner = ownerOf[tokenId];
        if (owner == address(0)) {
            ownerOf[tokenId] = to;
        } else {
            revert NameAlreadyExists(owner);
        }

        emit NameRegistered(name, to);
    }

    // Check if string is alphanumeric
    function _isAlphanumeric(string memory str) private pure returns (bool) {
        bytes memory b = bytes(str);
        for (uint256 i; i < b.length; i++) {
            bytes1 char = b[i];
            if (!(char > 0x2F && char < 0x3A) && !(char > 0x60 && char < 0x7B)) return false;
        }
        return true;
    }
}
