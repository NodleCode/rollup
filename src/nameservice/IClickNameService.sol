// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IClickNameService {
    /**
     * @notice Resolve name to address from L2
     * @param name string - Subdomain name to resolve
     * @return - address - Owner of the name
     */
    function resolve(string memory name) external view returns (address);

    /**
     * @notice Register an ENS subdomain with a default expiryDuration
     * @param to address   - Owner of the registered address
     * @param name string - Name to be registered
     */
    function register(address to, string memory name) external;

    /**
     * @notice Register an ENS subdomain with a specified expiration duration
     * @param to address   - Owner of the registered address
     * @param name string - Name to be registered
     * @param duration uint256 - Expiry duration
     */
    function registerWithExpiry(address to, string memory name, uint256 duration) external;
}
