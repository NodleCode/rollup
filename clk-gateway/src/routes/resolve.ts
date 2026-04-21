import { AbiCoder, dataSlice, getAddress, isAddress, isHexString } from "ethers"
import { Router } from "express"
import { body, matchedData, validationResult } from "express-validator"
import {
  clickNameServiceContract,
  clickNSDomain,
  l1ChainId,
  l1ResolverAddress,
  nameServiceContracts,
  nodleNameServiceContract,
  nodleNSDomain,
  resolutionSignatureTtlSeconds,
  resolverSigner,
} from "../setup"
import { HttpError } from "../types"
import { asyncHandler } from "../helpers"
import { parseDnsDomain, resolveFromL2 } from "../resolver/resolveFromL2"
import { signResolutionResponse } from "../resolver/signResolution"

const router = Router()

/**
 * CCIP-Read (ERC-3668) callback endpoint for the signed-gateway UniversalResolver.
 *
 * The L1 resolver emits `OffchainLookup(this, [url], callData, resolveWithSig, extraData)`
 * where `callData = abi.encode(bytes name, bytes data)`. CCIP-Read clients POST
 * that blob to this URL. We:
 *   1. Decode (name, data).
 *   2. Parse the DNS-encoded name and pick the correct L2 NameService contract.
 *   3. Dispatch the ENS call against L2 (addr / addr-multichain / text).
 *   4. EIP-712 sign Resolution(name, data, result, expiresAt).
 *   5. Return { data: abi.encode(result, expiresAt, signature) } so the client
 *      passes it verbatim to `resolveWithSig` on L1.
 */
router.post(
  "/",
  [
    body("sender")
      .optional()
      .isString()
      .withMessage("sender must be a string")
      .custom((value: string) => isAddress(value))
      .withMessage("sender must be a valid address"),
    body("data")
      .isString()
      .custom((value: string) => isHexString(value))
      .withMessage("data must be a hex string"),
  ],
  asyncHandler(async (req, res) => {
    if (!resolverSigner) {
      throw new HttpError(
        "Gateway signer not configured (RESOLVER_SIGNER_PRIVATE_KEY missing)",
        503,
      )
    }
    if (!l1ResolverAddress) {
      throw new HttpError(
        "Gateway L1 resolver address not configured (L1_RESOLVER_ADDR missing)",
        503,
      )
    }

    const result = validationResult(req)
    if (!result.isEmpty()) {
      throw new HttpError(
        result
          .array()
          .map((e: { msg: string }) => e.msg)
          .join(", "),
        400,
      )
    }

    const { data: ccipCallData, sender } = matchedData(req)

    // If the client provided a `sender`, ERC-3668 says it's the address of the
    // resolver that emitted OffchainLookup. Reject mismatches to cut down on
    // abuse surface — we only sign responses destined for our known L1 resolver.
    if (sender) {
      const normalizedSender = getAddress(sender as string)
      const expected = getAddress(l1ResolverAddress)
      if (normalizedSender !== expected) {
        throw new HttpError(
          `sender ${normalizedSender} does not match configured L1 resolver ${expected}`,
          400,
        )
      }
    }

    // callData from the OffchainLookup revert is abi.encode(bytes name, bytes data).
    // The ERC-3668 spec permits the client to prepend the resolver selector.
    // Strip it if present (the first 4 bytes are 0x <selector>).
    const abi = AbiCoder.defaultAbiCoder()
    let payload: string = ccipCallData
    // Heuristic: try decoding as (bytes,bytes) directly first; if it fails,
    // drop 4 bytes and retry. The contract sends raw abi.encode(name,data) with
    // no selector prefix, so the direct decode should normally succeed.
    let decodedName: string
    let decodedData: string
    try {
      const [n, d] = abi.decode(["bytes", "bytes"], payload)
      decodedName = n
      decodedData = d
    } catch (_err: unknown) {
      payload = dataSlice(ccipCallData, 4)
      const [n, d] = abi.decode(["bytes", "bytes"], payload)
      decodedName = n
      decodedData = d
    }

    const parsed = parseDnsDomain(Buffer.from(decodedName.slice(2), "hex"))

    // Route to the correct L2 NameService based on the parent domain.
    let nameServiceContract
    if (parsed.domain === clickNSDomain) {
      nameServiceContract = clickNameServiceContract
    } else if (parsed.domain === nodleNSDomain) {
      nameServiceContract = nodleNameServiceContract
    } else {
      // Fallback: try to find a matching contract by domain key.
      nameServiceContract = nameServiceContracts[parsed.domain]
    }

    if (!nameServiceContract) {
      throw new HttpError(
        `Unknown domain: ${parsed.domain || "<empty>"}`,
        404,
      )
    }

    if (!parsed.sub) {
      // Bare-domain queries are short-circuited on L1 by the resolver and should
      // never hit this callback. If one does, surface it clearly.
      throw new HttpError(
        "Bare-domain resolution is handled on L1 and should not reach the gateway",
        400,
      )
    }

    const resultBytes = await resolveFromL2({
      nameServiceContract,
      subdomain: parsed.sub,
      data: decodedData,
    })

    const expiresAt =
      Math.floor(Date.now() / 1000) + resolutionSignatureTtlSeconds

    const signedResponse = await signResolutionResponse({
      signer: resolverSigner,
      verifyingContract: l1ResolverAddress,
      chainId: l1ChainId,
      name: decodedName,
      data: decodedData,
      result: resultBytes,
      expiresAt,
    })

    res.status(200).send({ data: signedResponse })
  }),
)

export default router
