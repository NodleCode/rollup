import { getAddress, isAddress, isHexString } from "ethers"
import { Router } from "express"
import rateLimit from "express-rate-limit"
import { body, matchedData, query, validationResult } from "express-validator"
import { asyncHandler, buildTypedData, validateSignature } from "../helpers"
import { handleGuardService } from "../services/handleGuard"
import { rateLimitPerMin } from "../setup"
import { HttpError } from "../types"
import { normalizeHandle, validateHandle } from "../utils/handle"

const router = Router()

// Rate limiting for handle operations
const handleRateLimit = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    max: rateLimitPerMin,
    message: { error: "Too many requests, please try again later" },
    standardHeaders: true,
    legacyHeaders: false,
})

// Apply rate limiting to all handle routes
router.use(handleRateLimit)

// POST /handles/validate
router.post(
    "/validate",
    [
        body("handle")
            .isString()
            .withMessage("Handle must be a string")
            .custom((handle) => {
                const validation = validateHandle(handle)
                if (!validation.isValid) {
                    throw new Error(validation.error)
                }
                return true
            }),
        body("ensName")
            .isString()
            .matches(/^[a-z0-9-]+\.eth$/)
            .withMessage("ENS name must be a valid .eth domain"),
        body("owner")
            .isString()
            .custom((owner) => {
                if (!isAddress(owner)) {
                    throw new Error("Owner must be a valid Ethereum address")
                }
                return true
            }),
        body("signature")
            .isString()
            .custom((signature) => {
                if (!isHexString(signature)) {
                    throw new Error("Signature must be a hex string")
                }
                return true
            }),
        body("ttlSec")
            .optional()
            .isInt({ min: 60, max: 3600 })
            .withMessage("TTL must be between 60 and 3600 seconds"),
        body("idempotencyKey")
            .optional()
            .isString()
            .isLength({ min: 1, max: 64 })
            .withMessage("Idempotency key must be 1-64 characters"),
    ],
    asyncHandler(async (req, res) => {
        const result = validationResult(req)
        if (!result.isEmpty()) {
            throw new HttpError(
                result.array().map((error) => error.msg).join(", "),
                400
            )
        }

        const data = matchedData(req)
        const owner = getAddress(data.owner)

        // Build typed data for signature verification
        const typedData = buildTypedData({
            handle: normalizeHandle(data.handle),
            ensName: data.ensName,
            owner: owner,
            action: "validate_handle",
        }, {
            HandleValidation: [
                { name: "handle", type: "string" },
                { name: "ensName", type: "string" },
                { name: "owner", type: "address" },
                { name: "action", type: "string" },
            ],
        })

        const isValidSignature = validateSignature({
            typedData,
            signature: data.signature,
            expectedSigner: owner,
        })

        if (!isValidSignature) {
            throw new HttpError("Invalid signature", 403)
        }

        try {
            const response = await handleGuardService.validateHandle({
                handle: data.handle,
                ensName: data.ensName,
                owner: owner,
                ttlSec: data.ttlSec,
                idempotencyKey: data.idempotencyKey,
            })

            res.status(200).json(response)
        } catch (error: any) {
            if (error.statusCode) {
                const status = error.statusCode
                const responseBody: any = { error: error.message }

                if (error.status) {
                    responseBody.status = error.status
                }
                if (error.expiresInSec !== undefined) {
                    responseBody.expiresInSec = error.expiresInSec
                }

                res.status(status).json(responseBody)
            } else {
                throw error
            }
        }
    })
)

// POST /handles/confirm
router.post(
    "/confirm",
    [
        body("handle")
            .isString()
            .withMessage("Handle must be a string")
            .custom((handle) => {
                const validation = validateHandle(handle)
                if (!validation.isValid) {
                    throw new Error(validation.error)
                }
                return true
            }),
        body("txHash")
            .isString()
            .custom((txHash) => {
                if (!isHexString(txHash, 32)) {
                    throw new Error("Transaction hash must be a valid 32-byte hex string")
                }
                return true
            }),
        body("owner")
            .isString()
            .custom((owner) => {
                if (!isAddress(owner)) {
                    throw new Error("Owner must be a valid Ethereum address")
                }
                return true
            }),
        body("signature")
            .isString()
            .custom((signature) => {
                if (!isHexString(signature)) {
                    throw new Error("Signature must be a hex string")
                }
                return true
            }),
        body("extendTtlSec")
            .optional()
            .isInt({ min: 300, max: 7200 })
            .withMessage("Extended TTL must be between 300 and 7200 seconds"),
    ],
    asyncHandler(async (req, res) => {
        const result = validationResult(req)
        if (!result.isEmpty()) {
            throw new HttpError(
                result.array().map((error) => error.msg).join(", "),
                400
            )
        }

        const data = matchedData(req)
        const owner = getAddress(data.owner)

        // Build typed data for signature verification
        const typedData = buildTypedData({
            handle: normalizeHandle(data.handle),
            txHash: data.txHash,
            owner: owner,
            action: "confirm_handle",
        }, {
            HandleConfirmation: [
                { name: "handle", type: "string" },
                { name: "txHash", type: "string" },
                { name: "owner", type: "address" },
                { name: "action", type: "string" },
            ],
        })

        const isValidSignature = validateSignature({
            typedData,
            signature: data.signature,
            expectedSigner: owner,
        })

        if (!isValidSignature) {
            throw new HttpError("Invalid signature", 403)
        }

        try {
            const response = await handleGuardService.confirmHandle({
                handle: data.handle,
                txHash: data.txHash,
                owner: owner,
                extendTtlSec: data.extendTtlSec,
            })

            res.status(200).json(response)
        } catch (error: any) {
            if (error.statusCode) {
                res.status(error.statusCode).json({ error: error.message })
            } else {
                throw error
            }
        }
    })
)

// POST /handles/release
router.post(
    "/release",
    [
        body("handle")
            .isString()
            .withMessage("Handle must be a string")
            .custom((handle) => {
                const validation = validateHandle(handle)
                if (!validation.isValid) {
                    throw new Error(validation.error)
                }
                return true
            }),
        body("owner")
            .isString()
            .custom((owner) => {
                if (!isAddress(owner)) {
                    throw new Error("Owner must be a valid Ethereum address")
                }
                return true
            }),
        body("signature")
            .isString()
            .custom((signature) => {
                if (!isHexString(signature)) {
                    throw new Error("Signature must be a hex string")
                }
                return true
            }),
    ],
    asyncHandler(async (req, res) => {
        const result = validationResult(req)
        if (!result.isEmpty()) {
            throw new HttpError(
                result.array().map((error) => error.msg).join(", "),
                400
            )
        }

        const data = matchedData(req)
        const owner = getAddress(data.owner)

        // Build typed data for signature verification
        const typedData = buildTypedData({
            handle: normalizeHandle(data.handle),
            owner: owner,
            action: "release_handle",
        }, {
            HandleRelease: [
                { name: "handle", type: "string" },
                { name: "owner", type: "address" },
                { name: "action", type: "string" },
            ],
        })

        const isValidSignature = validateSignature({
            typedData,
            signature: data.signature,
            expectedSigner: owner,
        })

        if (!isValidSignature) {
            throw new HttpError("Invalid signature", 403)
        }

        try {
            const response = await handleGuardService.releaseHandle({
                handle: data.handle,
                owner: owner,
            })

            res.status(200).json(response)
        } catch (error: any) {
            if (error.statusCode) {
                res.status(error.statusCode).json({ error: error.message })
            } else {
                throw error
            }
        }
    })
)

// GET /handles/status
router.get(
    "/status",
    [
        query("handle")
            .isString()
            .withMessage("Handle must be a string")
            .custom((handle) => {
                const validation = validateHandle(handle)
                if (!validation.isValid) {
                    throw new Error(validation.error)
                }
                return true
            }),
    ],
    asyncHandler(async (req, res) => {
        const result = validationResult(req)
        if (!result.isEmpty()) {
            throw new HttpError(
                result.array().map((error) => error.msg).join(", "),
                400
            )
        }

        const data = matchedData(req)

        try {
            const response = await handleGuardService.getHandleStatus(data.handle)
            res.status(200).json(response)
        } catch (error: any) {
            if (error.statusCode) {
                res.status(error.statusCode).json({ error: error.message })
            } else {
                throw error
            }
        }
    })
)

export default router
