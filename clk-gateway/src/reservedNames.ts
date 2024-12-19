/**
 * @file reservedNames.ts
 * @description This file contains a simple tool to create the hashes of the names we want the clk-gateway to keep reserved for manual registration.
 *
 * The `reservedNames` array holds the names that are reserved. The `createHashes` function generates keccak256 hashes for these names and logs them.
 *
 * The names are converted to lowercase, appended with ".clk.eth", and validated as Fully Qualified Domain Names (FQDNs) before hashing.
 *
 * Dependencies:
 * - ethers: For keccak256 hashing and UTF-8 byte conversion.
 * - validator: For FQDN validation.
 *
 * Usage:
 * - Populate the `reservedNames` array with the names you want to reserve.
 * - Run the script to generate and log the hashes. Then insert the hashes into the `reservedHashes` array in the `reservedHashes.ts` file.
 */

import { keccak256, toUtf8Bytes } from "ethers";

import isFQDN from "validator/lib/isFQDN";

// Populate this array with reserved names
export const reservedNames: readonly string[] = ["click"];
export default reservedNames;

// Create hashes for reserved names
function createHashes() {
  const hashes: string[] = [];
  reservedNames.forEach((name) => {
    const sub = name.toLowerCase();
    const fullName = sub + ".clk.eth";
    if (!isFQDN(fullName)) {
      console.log(`Invalid FQDN: ${sub}`);
      throw new Error("Invalid FQDN");
    }
    const hash = keccak256(toUtf8Bytes(sub));
    hashes.push(hash);
  });
  console.dir(hashes, { maxArrayLength: null });
}

createHashes();
