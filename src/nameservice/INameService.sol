// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface INameService {
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

    /**
     * @notice Set a text record for a name
     * @param name string - Name to set the text record for
     * @param key string - Key of the text record
     * @param value string - Value of the text record
     */
    function setTextRecord(string memory name, string memory key, string memory value) external;

    /**
     * @notice Get a text record for a name
     * @param name string - Name to get the text record for
     * @param key string - Key of the text record
     * @return string - Value of the text record
     */
    function getTextRecord(string memory name, string memory key) external view returns (string memory);
}
