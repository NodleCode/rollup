import express, { Request, Response } from "express";
import { Provider as L2Provider, Wallet } from "zksync-ethers";
import {
  JsonRpcProvider as L1Provider,
  keccak256,
  toBigInt,
  toUtf8Bytes,
  AbiCoder,
  getAddress,
  Contract,
} from "ethers";
import { CommitBatchInfo, StoredBatchInfo as BatchInfo } from "./types";
import {
  ZKSYNC_DIAMOND_INTERFACE,
  CLICK_NAME_SERVICE_INTERFACE,
  CLICK_RESOLVER_INTERFACE,
  CLICK_NAME_SERVICE_OWNERS_STORAGE_SLOT,
} from "./interfaces";
import { isValidSubdomain } from "./validators";
import dotenv from "dotenv";
import admin from "firebase-admin";
import { initializeApp } from "firebase-admin/app";

dotenv.config();

const app = express();
app.use(express.json());

const port = process.env.PORT || 8080;
const privateKey = process.env.REGISTRAR_PRIVATE_KEY!;
const l2Provider = new L2Provider(process.env.L2_RPC_URL!);
const l2Wallet = new Wallet(privateKey, l2Provider);
const l1Provider = new L1Provider(process.env.L1_RPC_URL!);
const diamondAddress = process.env.DIAMOND_PROXY_ADDR!;
const diamondContract = new Contract(
  diamondAddress,
  ZKSYNC_DIAMOND_INTERFACE,
  l1Provider
);
const clickResolverAddress = process.env.CLICK_RESOLVER_ADDR!;
const clickResolverContract = new Contract(
  clickResolverAddress,
  CLICK_RESOLVER_INTERFACE,
  l1Provider
);
const clickNameServiceAddress = process.env.CNS_ADDR!;
const clickNameServiceContract = new Contract(
  clickNameServiceAddress,
  CLICK_NAME_SERVICE_INTERFACE,
  l2Wallet
);
const batchQueryOffset = Number(process.env.SAFE_BATCH_QUERY_OFFSET!);
const serviceAccountKey = process.env.SERVICE_ACCOUNT_KEY!;
const serviceAccount = JSON.parse(serviceAccountKey);
const firebaseApp = initializeApp({
  credential: admin.credential.cert(serviceAccount as admin.ServiceAccount),
});

/** Parses the transaction where batch is committed and returns commit info */
async function parseCommitTransaction(
  txHash: string,
  batchNumber: number
): Promise<{ commitBatchInfo: CommitBatchInfo; commitment: string }> {
  const transactionData = await l1Provider.getTransaction(txHash);
  const [, , newBatch] = ZKSYNC_DIAMOND_INTERFACE.decodeFunctionData(
    "commitBatchesSharedBridge",
    transactionData!.data
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
    [batchNumber]
  );
  const commitLog = receipt.logs.find(
    (log) =>
      log.address === diamondAddress &&
      blockCommitFilter.every((topic, i) => topic === log.topics[i])
  );
  if (commitLog == undefined) {
    throw new Error(`Commit log for batch ${batchNumber} not found`);
  }
  const { commitment } = ZKSYNC_DIAMOND_INTERFACE.decodeEventLog(
    "BlockCommit",
    commitLog.data,
    commitLog.topics
  );

  return { commitBatchInfo, commitment };
}
/** Returns logs root hash stored in L1 contract */
async function getL2LogsRootHash(batchNumber: number): Promise<string> {
  const l2RootsHash = await diamondContract.l2LogsRootHash(batchNumber);
  return String(l2RootsHash);
}

/**
 * Returns the batch info for the given batch number for those stored on L1.
 * Returns null if the batch is not stored.
 * @param batchNumber
 */
async function getBatchInfo(batchNumber: number): Promise<BatchInfo> {
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
    batchNumber
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

// Health endpoint to check the status of L1 and L2 connections.
// This endpoint verifies that the batch number used for L1 APIs is committed to L1 as expected.
// The service intentionally stays behind the latest batch number by SAFE_BATCH_QUERY_OFFSET to ensure the batch is already committed and proved.
app.get("/health", async (req: Request, res: Response) => {
  try {
    const l1BatchNumber = await l2Provider.getL1BatchNumber();

    const batchNumber = l1BatchNumber - batchQueryOffset;

    const batchDetails = await l2Provider.getL1BatchDetails(batchNumber);

    if (batchDetails.commitTxHash == undefined) {
      throw new Error(`Batch ${batchNumber} is not committed`);
    }

    const batchInfo = await getBatchInfo(batchNumber);

    res.status(200).send({
      batchNumber: batchInfo.batchNumber.toString(),
      batchHash: batchInfo.batchHash,
      status: "ok",
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    res.status(500).send({ error: errorMessage });
  }
});

app.get("/expiryL2", async (req: Request, res: Response) => {
  try {
    const { name } = req.query;

    if (!name || typeof name !== "string" || !isValidSubdomain(name)) {
      res.status(400).json({
        error:
          "Name is required and must be a string adhering to DNS subdomain requirements",
      });
      return;
    }

    const nameHash = keccak256(toUtf8Bytes(name));
    const key = toBigInt(nameHash);

    const epoch = await clickNameServiceContract.expires(nameHash);
    const expires = new Date(Number(epoch) * 1000).toISOString();

    res.status(200).send({
      expires,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    res.status(500).send({ error: errorMessage });
  }
});

app.get("/resolveL2", async (req: Request, res: Response) => {
  try {
    const { name } = req.query;

    if (!name || typeof name !== "string" || !isValidSubdomain(name)) {
      res.status(400).json({
        error:
          "Name is required and must be a string adhering to DNS subdomain requirements",
      });
      return;
    }

    const owner = await clickNameServiceContract.resolve(name);

    res.status(200).send({
      owner,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    res.status(500).send({ error: errorMessage });
  }
});

app.get("/storageProvedOwnerL2", async (req: Request, res: Response) => {
  try {
    const { name } = req.query;

    if (!name || typeof name !== "string" || !isValidSubdomain(name)) {
      res.status(400).json({
        error:
          "Name is required and must be a string adhering to DNS subdomain requirements",
      });
      return;
    }

    const token = toBigInt(keccak256(toUtf8Bytes(name)));

    const key = keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["uint256", "uint256"],
        [token, CLICK_NAME_SERVICE_OWNERS_STORAGE_SLOT]
      )
    );

    const l1BatchNumber = await l2Provider.getL1BatchNumber();

    const proof = await l2Provider.getProof(
      clickNameServiceAddress,
      [key],
      l1BatchNumber
    );
    const rawOwner = proof.storageProof[0].value;
    const owner = getAddress("0x" + rawOwner.slice(26));

    res.status(200).send({
      owner,
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    res.status(500).send({ error: errorMessage });
  }
});

app.post("/registerL2", async (req: Request, res: Response) => {
  try {
    const { name, owner } = req.body;

    const authHeader = req.headers.authorization;
    if (!authHeader) {
      res.status(401).json({ error: "Authorization header is missing" });
      return;
    }
    const idToken = authHeader.split("Bearer ")[1];
    if (!idToken) {
      res.status(401).json({ error: "Bearer token is missing" });
      return;
    }
    const decodedToken = await admin.auth().verifyIdToken(idToken);
    if (!decodedToken.email_verified) {
      res.status(403).json({ error: "Email not verified" });
      return;
    }

    if (!name || typeof name !== "string" || !isValidSubdomain(name)) {
      res.status(400).json({
        error:
          "Name is required and must be a string adhering to DNS subdomain requirements",
      });
      return;
    }

    const ownerAddress = getAddress(owner);

    const response = await clickNameServiceContract.register(
      ownerAddress,
      name
    );
    const receipt = await response.wait();

    if (receipt.status !== 1) {
      throw new Error("Transaction failed");
    }

    res.status(200).send({
      txHash: receipt.hash,
    });
  } catch (error) {
    const message =
      error && typeof error === "object" && "message" in error
        ? error.message
        : String(error);
    res.status(500).send({ error: message });
  }
});

// Start server
app.listen(port, () => {
  console.log(`Server is running on port ${port}`);
});
