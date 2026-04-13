import { AbiCoder, Contract, dataSlice, ZeroAddress } from "ethers"
import { NAME_SERVICE_INTERFACE } from "../interfaces"

// ENS resolver selectors
export const ADDR_SELECTOR = "0x3b3b57de" // addr(bytes32)
export const ADDR_MULTICHAIN_SELECTOR = "0xf1cb7e06" // addr(bytes32,uint256)
export const TEXT_SELECTOR = "0x59d1d43c" // text(bytes32,string)
export const ZKSYNC_MAINNET_COIN_TYPE = 2147483972n // (0x80000000 | 0x144) per ENSIP-11

/**
 * Parse a DNS-encoded ENS name into its segments.
 * `example.clave.eth` → { sub: "example", domain: "clave", tld: "eth" }
 * Mirrors `_parseDnsDomain` in UniversalResolver.sol.
 */
export function parseDnsDomain(
  dnsName: Uint8Array,
): { sub: string; domain: string; tld: string } {
  const out = { sub: "", domain: "", tld: "" }
  let offset = 0
  const segments: string[] = []
  while (offset < dnsName.length) {
    const len = dnsName[offset]
    if (len === 0) break
    segments.push(Buffer.from(dnsName.slice(offset + 1, offset + 1 + len)).toString("utf8"))
    offset += 1 + len
  }
  if (segments.length === 1) {
    out.tld = segments[0]
  } else if (segments.length === 2) {
    out.domain = segments[0]
    out.tld = segments[1]
  } else if (segments.length >= 3) {
    out.sub = segments[0]
    out.domain = segments[1]
    out.tld = segments[2]
  }
  return out
}

/**
 * Resolve an ENS query against the L2 NameService and return ABI-encoded result
 * bytes ready to be signed and returned via CCIP-Read.
 *
 * Throws on unsupported selectors / coin types.
 * Returns ABI-encoded zero value (`address(0)` or empty string) if the name is
 * expired or not found — the gateway does not leak per-name existence.
 */
export async function resolveFromL2({
  nameServiceContract,
  subdomain,
  data,
}: {
  nameServiceContract: Contract
  subdomain: string
  data: string // hex-encoded ENS call data
}): Promise<string> {
  const selector = dataSlice(data, 0, 4).toLowerCase()
  const abi = AbiCoder.defaultAbiCoder()

  if (selector === ADDR_SELECTOR || selector === ADDR_MULTICHAIN_SELECTOR) {
    if (selector === ADDR_MULTICHAIN_SELECTOR) {
      const [, coinType] = abi.decode(["bytes32", "uint256"], dataSlice(data, 4))
      if (BigInt(coinType) !== ZKSYNC_MAINNET_COIN_TYPE) {
        throw new Error(`Unsupported coinType: ${coinType}`)
      }
    }

    try {
      const owner: string = await nameServiceContract.resolve(subdomain)
      return abi.encode(["address"], [owner])
    } catch (_e: unknown) {
      // Expired or non-existent → return zero address (ENS "no record" convention)
      return abi.encode(["address"], [ZeroAddress])
    }
  }

  if (selector === TEXT_SELECTOR) {
    const [, key] = abi.decode(["bytes32", "string"], dataSlice(data, 4))
    try {
      const value: string = await nameServiceContract.getTextRecord(subdomain, key)
      return abi.encode(["string"], [value])
    } catch (_e: unknown) {
      return abi.encode(["string"], [""])
    }
  }

  throw new Error(`Unsupported selector: ${selector}`)
}

// Re-exported for tests / call sites that need to encode ABI directly.
export { NAME_SERVICE_INTERFACE }
