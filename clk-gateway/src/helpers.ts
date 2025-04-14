import admin from "firebase-admin";
import { NextFunction, Request, Response } from "express";
import { toUtf8Bytes, ErrorDescription, verifyMessage, keccak256 } from "ethers";
import {
  CommitBatchInfo,
  StoredBatchInfo as BatchInfo,
  ZyfiSponsoredRequest,
  ZyfiSponsoredResponse,
  HttpError,
} from "./types";
import {
  diamondAddress,
  diamondContract,
  l1Provider,
  l2Provider,
} from "./setup";
import { ZKSYNC_DIAMOND_INTERFACE } from "./interfaces";
import { zyfiSponsoredUrl } from "./setup";
import { DecodedIdToken } from "firebase-admin/lib/auth/token-verifier";

export function toLengthPrefixedBytes(
  sub: string,
  domain: string,
  top: string,
): Uint8Array {
  const totalLength = sub.length + domain.length + top.length + 3;
  const buffer = new Uint8Array(totalLength);

  let offset = 0;
  for (const part of [sub, domain, top]) {
    buffer.set([part.length], offset);
    buffer.set(toUtf8Bytes(part), offset + 1);
    offset += part.length + 1;
  }

  return buffer;
}

export function isParsableError(
  error: any,
): error is { data: string | Uint8Array } {
  return (
    error &&
    typeof error === "object" &&
    "data" in error &&
    error.data &&
    (typeof error.data === "string" || error.data instanceof Uint8Array)
  );
}

export type OffchainLookupArgs = {
  sender: string;
  urls: string[];
  callData: string;
  callbackFunction: string;
  extraData: string;
};

export function isOffchainLookupError(
  errorDisc: null | ErrorDescription,
): errorDisc is ErrorDescription & { args: OffchainLookupArgs } {
  return (
    errorDisc !== null &&
    typeof errorDisc.name === "string" &&
    errorDisc.name === "OffchainLookup" &&
    Array.isArray(errorDisc.args) &&
    typeof errorDisc.args[0] === "string" &&
    Array.isArray(errorDisc.args[1]) &&
    errorDisc.args[1].every((url: unknown) => typeof url === "string") &&
    typeof errorDisc.args[2] === "string" &&
    typeof errorDisc.args[3] === "string" &&
    typeof errorDisc.args[4] === "string"
  );
}

/** Parses the transaction where batch is committed and returns commit info */
export async function parseCommitTransaction(
  txHash: string,
  batchNumber: number,
): Promise<{ commitBatchInfo: CommitBatchInfo; commitment: string }> {
  const transactionData = await l1Provider.getTransaction(txHash);
  const [, , newBatch] = ZKSYNC_DIAMOND_INTERFACE.decodeFunctionData(
    "commitBatchesSharedBridge",
    transactionData!.data,
  );

  // Find the batch with matching number
  const batch = newBatch.find((batch: any) => {
    return batch[0] === BigInt(batchNumber);
  });
  if (batch == undefined) {
    throw new Error(`Batch ${batchNumber} not found in calldata`);
  }

  const commitBatchInfo: CommitBatchInfo = {
    batchNumber: batch[0],
    timestamp: batch[1],
    indexRepeatedStorageChanges: batch[2],
    newStateRoot: batch[3],
    numberOfLayer1Txs: batch[4],
    priorityOperationsHash: batch[5],
    bootloaderHeapInitialContentsHash: batch[6],
    eventsQueueStateHash: batch[7],
    systemLogs: batch[8],
    totalL2ToL1Pubdata: batch[9],
  };

  const receipt = await l1Provider.getTransactionReceipt(txHash);
  if (receipt == undefined) {
    throw new Error(`Receipt for commit tx ${txHash} not found`);
  }

  // Parse event logs of the transaction to find commitment
  const blockCommitFilter = ZKSYNC_DIAMOND_INTERFACE.encodeFilterTopics(
    "BlockCommit",
    [batchNumber],
  );
  const commitLog = receipt.logs.find(
    (log) =>
      log.address === diamondAddress &&
      blockCommitFilter.every((topic, i) => topic === log.topics[i]),
  );
  if (commitLog == undefined) {
    throw new Error(`Commit log for batch ${batchNumber} not found`);
  }
  const { commitment } = ZKSYNC_DIAMOND_INTERFACE.decodeEventLog(
    "BlockCommit",
    commitLog.data,
    commitLog.topics,
  );

  return { commitBatchInfo, commitment };
}
/** Returns logs root hash stored in L1 contract */
export async function getL2LogsRootHash(batchNumber: number): Promise<string> {
  const l2RootsHash = await diamondContract.l2LogsRootHash(batchNumber);
  return String(l2RootsHash);
}

/**
 * Returns the batch info for the given batch number for those stored on L1.
 * Returns null if the batch is not stored.
 * @param batchNumber
 */
export async function getBatchInfo(batchNumber: number): Promise<BatchInfo> {
  const { commitTxHash, proveTxHash } =
    await l2Provider.getL1BatchDetails(batchNumber);

  // If batch is not committed or proved, return null
  if (commitTxHash == undefined) {
    throw new Error(`Batch ${batchNumber} is not committed`);
  } else if (proveTxHash == undefined) {
    throw new Error(`Batch ${batchNumber} is not proved`);
  }

  // Parse commit calldata from commit transaction
  const { commitBatchInfo, commitment } = await parseCommitTransaction(
    commitTxHash,
    batchNumber,
  );
  const l2LogsTreeRoot = await getL2LogsRootHash(batchNumber);

  const storedBatchInfo: BatchInfo = {
    batchNumber: commitBatchInfo.batchNumber,
    batchHash: commitBatchInfo.newStateRoot,
    indexRepeatedStorageChanges: commitBatchInfo.indexRepeatedStorageChanges,
    numberOfLayer1Txs: commitBatchInfo.numberOfLayer1Txs,
    priorityOperationsHash: commitBatchInfo.priorityOperationsHash,
    l2LogsTreeRoot,
    timestamp: commitBatchInfo.timestamp,
    commitment,
  };
  return storedBatchInfo;
}

export async function fetchZyfiSponsored(
  request: ZyfiSponsoredRequest,
): Promise<ZyfiSponsoredResponse> {
  console.log(`zyfiSponsoredUrl: ${zyfiSponsoredUrl}`);
  const response = await fetch(zyfiSponsoredUrl!, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-KEY": process.env.ZYFI_API_KEY!,
    },
    body: JSON.stringify(request),
  });

  if (!response.ok) {
    throw new Error(`Failed to fetch zyfi sponsored`);
  }
  const sponsoredResponse = (await response.json()) as ZyfiSponsoredResponse;

  return sponsoredResponse;
}

/**
 * Validate an Ethereum signature
 * @param {Object} params - Signature validation parameters
 * @param {string} params.message - Original message that was signed
 * @param {string} params.signature - Signature to validate
 * @param {string} params.expectedSigner - Expected signer's address
 * @returns {boolean} - Whether the signature is valid
 */
export function validateSignature({ message, signature, expectedSigner }: {
  message: string,
  signature: string,
  expectedSigner: string,
}) {
  try {
    const signerAddress = verifyMessage(
      message, 
      signature
    );

    return signerAddress.toLowerCase() === expectedSigner.toLowerCase();
  } catch (error) {
    console.error('Signature validation error:', error);
    return false;
  }
}

/**
 * Get the hash of a message
 * @param {Object} data - Message data
 * @param {string} data.name - Name of the message
 * @param {string} data.owner - Owner of the message
 * @returns {string} - Hash of the message
 */
export function getMessageHash(data: {
  name: string,
}) {
  const message = data;
  const messageHash = keccak256(toUtf8Bytes(JSON.stringify(message)));

  return messageHash;
}

/**
 * Validate the header of the request
 * @param {Request} req - The request object
 * @returns {DecodedIdToken} - The decoded token
*/
export async function getDecodedToken(req: Request): Promise<DecodedIdToken> {
  const authHeader = req.headers.authorization;
  if (!authHeader) {
    throw new HttpError("Authorization header is missing", 401);
  }
  const idToken = authHeader.split("Bearer ")[1];
  if (!idToken) {
    throw new HttpError("Bearer token is missing", 401);
  }
  const decodedToken = await admin.auth().verifyIdToken(idToken, true);
  if (!decodedToken.email_verified) {
    throw new HttpError("Email not verified", 403);
  }
  if (decodedToken.subDomain) {
    throw new HttpError(
      "One subdomain already claimed with this email address",
      403
    );
  }

  return decodedToken;
}

/**
 * Check if a user exists by email
 * @param {Request} req - The request object
 * @returns {void} - The user
*/
export async function checkUserByEmail(req: Request): Promise<void> {
  const user = await admin.auth().getUserByEmail(req.body.email).catch(reason => {
    if (reason.code === "auth/user-not-found") {
      return null;
    }
    throw new HttpError(reason.message, 403);
  });
  if (user?.customClaims?.subDomain) {
    throw new HttpError(
      "One subdomain already claimed with this email address",
      403
    );
  }
}

/**
 * Async handler for express routes
 * @returns {Function} - The async handler
*/
export const asyncHandler = (
  handler: (req: Request, res: Response, next: NextFunction) => Promise<void>
) => {
  return async (req: Request, res: Response, next: NextFunction) => {
    try {
      await handler(req, res, next);
    } catch (error) {
      next(error);
    }
  };
};

export function buildTypedData(data: {
  name: string,
}) {
  const domain = domain;
  
  const message = data;
  const messageHash = keccak256(toUtf8Bytes(JSON.stringify(message)));

  return messageHash;
}