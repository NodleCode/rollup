import { AbiCoder, getBytes, TypedDataDomain, Wallet } from "ethers"

/**
 * EIP-712 domain parameters that MUST match the L1 UniversalResolver deployment.
 * If these diverge, signatures will not recover to the trusted signer on-chain.
 *
 * Contract constructor: EIP712("NodleUniversalResolver", "1")
 */
export const RESOLUTION_DOMAIN_NAME = "NodleUniversalResolver"
export const RESOLUTION_DOMAIN_VERSION = "1"

/**
 * EIP-712 types used for the signed CCIP-Read response.
 * Contract typehash: keccak256("Resolution(bytes name,bytes data,bytes result,uint64 expiresAt)")
 */
const RESOLUTION_TYPES = {
  Resolution: [
    { name: "name", type: "bytes" },
    { name: "data", type: "bytes" },
    { name: "result", type: "bytes" },
    { name: "expiresAt", type: "uint64" },
  ],
}

export interface SignResolutionArgs {
  signer: Wallet
  verifyingContract: string
  chainId: number
  name: string // hex-encoded DNS-packed ENS name
  data: string // hex-encoded original ENS call data
  result: string // hex-encoded ABI-encoded resolution result
  expiresAt: number // unix seconds
}

/**
 * Sign a CCIP-Read Resolution payload with EIP-712.
 *
 * Returns the ABI-encoded `(bytes result, uint64 expiresAt, bytes signature)`
 * blob that the L1 UniversalResolver's `resolveWithSig` callback expects as its
 * first (`_response`) argument.
 */
export async function signResolutionResponse({
  signer,
  verifyingContract,
  chainId,
  name,
  data,
  result,
  expiresAt,
}: SignResolutionArgs): Promise<string> {
  const domain: TypedDataDomain = {
    name: RESOLUTION_DOMAIN_NAME,
    version: RESOLUTION_DOMAIN_VERSION,
    chainId,
    verifyingContract,
  }

  const message = {
    name: getBytes(name),
    data: getBytes(data),
    result: getBytes(result),
    expiresAt,
  }

  const signature = await signer.signTypedData(domain, RESOLUTION_TYPES, message)

  return AbiCoder.defaultAbiCoder().encode(
    ["bytes", "uint64", "bytes"],
    [result, expiresAt, signature],
  )
}
