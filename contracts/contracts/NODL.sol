// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract NODL is Initializable, OwnableUpgradeable, ERC20CappedUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) initializer public {
        __ERC20_init("Nodle Token", "NODL");
        __ERC20Capped_init(21000000000 * (10 ** 18)); // 21B with 18 decimals
        __Ownable_init();

        _transferOwnership(owner);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}