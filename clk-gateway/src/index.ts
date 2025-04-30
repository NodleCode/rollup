import express, { NextFunction, Request, Response } from "express";
import { query, body, matchedData, validationResult } from "express-validator";
import cors from "cors";
import {
  keccak256,
  toBigInt,
  toUtf8Bytes,
  AbiCoder,
  getAddress,
  isHexString,
  ZeroAddress,
  isAddress,
  ethers,
} from "ethers";
import { HttpError, StorageProof } from "./types";
import {
  CLICK_RESOLVER_INTERFACE,
  STORAGE_PROOF_TYPE,
  CLICK_RESOLVER_ADDRESS_SELECTOR,
  NAME_SERVICE_INTERFACE,
} from "./interfaces";
import {
  toLengthPrefixedBytes,
  isParsableError,
  isOffchainLookupError,
  safeUtf8Decode,
  getNameServiceAddressByDomain,
} from "./helpers";
import admin from "firebase-admin";
import {
  port,
  l2Provider,
  l2Wallet,
  clickResolverContract,
  clickNameServiceAddress,
  clickNameServiceContract,
  batchQueryOffset,
  clickNSDomain,
  nodleNSDomain,
  parentTLD,
  zyfiSponsoredUrl,
  buildZyfiRegisterRequest,
} from "./setup";
import { getBatchInfo, fetchZyfiSponsored } from "./helpers";
import reservedHashes from "./reservedHashes";
import namesRouter from "./routes/names";

const app = express();
app.use(express.json());

const corsOptions = {
  origin: "*",
  methods: ["GET", "POST", "OPTIONS", "PUT", "DELETE"],
  allowedHeaders: ["Content-Type", "Authorization"],
};
app.use(cors(corsOptions));

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

app.get(
  "/expiryL2",
  query("name").isString().withMessage("Name is required and must be a string"),
  async (req: Request, res: Response) => {
    try {
      const result = validationResult(req);
      if (!result.isEmpty()) {
        res.status(400).json(result.array());
        return;
      }
      const name = matchedData(req).name;

      const nameHash = keccak256(toUtf8Bytes(name));
      const key = toBigInt(nameHash);

      const epoch = await clickNameServiceContract.expires(nameHash);
      const expires = new Date(Number(epoch) * 1000).toISOString();

      res.status(200).send({
        expires,
      });
    } catch (error) {
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      res.status(500).send({ error: errorMessage });
    }
  }
);

app.get(
  "/resolveL2",
  query("name").isString().withMessage("Name is required and must be a string"),
  async (req: Request, res: Response) => {
    try {
      const result = validationResult(req);
      if (!result.isEmpty()) {
        res.status(400).json(result.array());
        return;
      }
      const name = matchedData(req).name;

      const owner = await clickNameServiceContract.resolve(name);

      res.status(200).send({
        owner,
      });
    } catch (error) {
      if (isParsableError(error)) {
        const decodedError = NAME_SERVICE_INTERFACE.parseError(
          error.data
        );
        if (decodedError !== null && typeof decodedError.name === "string") {
          if (decodedError.name === "ERC721NonexistentToken") {
            res.status(404).send({ error: "Name not found" });
            return;
          }
          if (decodedError.name === "NameExpired") {
            res.status(410).send({ error: "Name expired" });
            return;
          }
        }
      }
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      res.status(500).send({ error: errorMessage });
    }
  }
);

app.post(
  "/resolveL1",
  body("name")
    .isFQDN()
    .withMessage("Name must be a fully qualified domain name")
    .custom((name) => {
      const [sub, domain, tld] = name.split(".");
      if ([`${clickNSDomain}.${parentTLD}`, `${nodleNSDomain}.${parentTLD}`].includes(`${domain}.${tld}`)) {
        return false;
      }
      return true;
    })
    .withMessage("Invalid domain or tld"),
  async (req: Request, res: Response) => {
    try {
      const result = validationResult(req);
      if (!result.isEmpty()) {
        res.status(400).json(result.array());
        return;
      }
      const name = matchedData(req).name;

      const parts = name.split(".");
      const [sub, domain, tld] = parts;

      const encodedFqdn = toLengthPrefixedBytes(sub, domain, tld);

      const owner = await clickResolverContract.resolve(
        encodedFqdn,
        CLICK_RESOLVER_ADDRESS_SELECTOR
      );

      res.status(200).send({
        owner,
      });
    } catch (error) {
      if (isParsableError(error)) {
        const decodedError = CLICK_RESOLVER_INTERFACE.parseError(error.data);
        if (isOffchainLookupError(decodedError)) {
          const { sender, urls, callData, callbackFunction, extraData } =
            decodedError.args;
          res.status(200).send({
            OffchainLookup: {
              sender,
              urls,
              callData,
              callbackFunction,
              extraData,
            },
          });
          return;
        }
      }
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      res.status(500).send({ error: errorMessage });
    }
  }
);

app.post(
  "/resolveWithProofL1",
  [
    body("proof")
      .isString()
      .custom((proof) => {
        return isHexString(proof);
      })
      .withMessage("Proof must be a hex string"),
    body("key")
      .isString()
      .custom((key) => {
        return isHexString(key, 32);
      })
      .withMessage("Key must be a 32 bytes hex string"),
  ],
  async (req: Request, res: Response) => {
    try {
      const result = validationResult(req);
      if (!result.isEmpty()) {
        res.status(400).json(result.array());
        return;
      }
      const data = matchedData(req);
      const rawOwner = await clickResolverContract.resolveWithProof(
        data.proof,
        data.key
      );
      const owner = getAddress("0x" + rawOwner.slice(26));
      if (owner === ZeroAddress) {
        res
          .status(404)
          .send({ error: "Owner not found or not yet proved to L1" });
        return;
      }

      res.status(200).send({
        owner,
      });
    } catch (error) {
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      res.status(500).send({ error: errorMessage });
    }
  }
);

app.get(
  "/storageProof",
  [
    query("key")
      .isString()
      .custom((key) => {
        return isHexString(key);
      })
      .withMessage("Key must be hex string"),
    query("sender")
      .isString()
      .custom((sender) => {
        return isAddress(sender);
      })
      .withMessage("Sender must be a valid Ethereum address"),
  ],
  async (req: Request, res: Response) => {
    try {
      const result = validationResult(req);
      if (!result.isEmpty()) {
        res.status(400).json(result.array());
        return;
      }
      const codedData = matchedData(req).key;
      const [key, domain] = AbiCoder.defaultAbiCoder().decode(
        codedData.length === 66 ? ["bytes32"] : ["bytes32", "string"],
        codedData
      );
      const nameServiceAddress = getNameServiceAddressByDomain(domain || "clk");
      // const sender = matchedData(req).sender;
      const l1BatchNumber = await l2Provider.getL1BatchNumber();
      const batchNumber = l1BatchNumber - batchQueryOffset;

      const initialProof = await l2Provider.getProof(
        nameServiceAddress,
        [key],
        batchNumber
      );

      const lengthValue = parseInt(initialProof.storageProof[0].value, 16);
      const isLongString = lengthValue & 1; // last bit indicates if it's a long string

      if (!isLongString) {

        const batchInfo = await getBatchInfo(batchNumber);

        const storageProof: StorageProof = {
          account: initialProof.address,
          key: initialProof.storageProof[0].key,
          path: initialProof.storageProof[0].proof,
          value: initialProof.storageProof[0].value,
          index: initialProof.storageProof[0].index,
          metadata: {
            batchNumber: batchInfo.batchNumber,
            indexRepeatedStorageChanges: batchInfo.indexRepeatedStorageChanges,
            numberOfLayer1Txs: batchInfo.numberOfLayer1Txs,
            priorityOperationsHash: batchInfo.priorityOperationsHash,
            l2LogsTreeRoot: batchInfo.l2LogsTreeRoot,
            timestamp: batchInfo.timestamp,
            commitment: batchInfo.commitment,
          },
        };

        // decode the value
        const value = initialProof.storageProof[0].value;
        const decodedValue = safeUtf8Decode(value);

        const data = AbiCoder.defaultAbiCoder().encode(
          [STORAGE_PROOF_TYPE, "string"],
          [storageProof, decodedValue]
        );
        res.status(200).send({
          data,
        });
        return;
      }

      // Long string: calculate real length and slots needed
      const stringLength = (lengthValue - 1) / 2;
      const slotsNeeded = Math.ceil(stringLength / 32);

      // Generate slots for the data
      const slots = [key];
      const baseSlot = ethers.keccak256(key);
      for (let i = 0; i < slotsNeeded; i++) {
        const slotNum = ethers.getBigInt(baseSlot) + BigInt(i);
        const paddedHex = "0x" + slotNum.toString(16).padStart(64, "0");
        slots.push(paddedHex);
      }
      // Get proofs for all necessary slots
      const proof = await l2Provider.getProof(
        nameServiceAddress,
        slots,
        batchNumber
      );

      // Concatenate only the necessary bytes
      let fullValue = "0x";
      for (let i = 1; i < proof.storageProof.length && i <= slotsNeeded; i++) {
        const value = proof.storageProof[i].value.slice(2);
        if (i === slotsNeeded) {
          // last slot
          const remainingBytes = stringLength - 32 * (i - 1);
          fullValue += value.slice(0, remainingBytes * 2);
        } else {
          fullValue += value;
        }
      }

      const batchInfo = await getBatchInfo(batchNumber);

      const storageProof: StorageProof = {
        account: initialProof.address,
        key: initialProof.storageProof[0].key,
        path: initialProof.storageProof[0].proof,
        value: initialProof.storageProof[0].value,
        index: initialProof.storageProof[0].index,
        metadata: {
          batchNumber: batchInfo.batchNumber,
          indexRepeatedStorageChanges: batchInfo.indexRepeatedStorageChanges,
          numberOfLayer1Txs: batchInfo.numberOfLayer1Txs,
          priorityOperationsHash: batchInfo.priorityOperationsHash,
          l2LogsTreeRoot: batchInfo.l2LogsTreeRoot,
          timestamp: batchInfo.timestamp,
          commitment: batchInfo.commitment,
        },
      };

      // decode the value
      const decodedValue = safeUtf8Decode(fullValue);

      const data = AbiCoder.defaultAbiCoder().encode(
        [STORAGE_PROOF_TYPE, "string"],
        [storageProof, decodedValue]
      );
      res.status(200).send({
        data,
      });
    } catch (error) {
      const errorMessage =
        error instanceof Error ? error.message : String(error);
      res.status(500).send({ error: errorMessage });
    }
  }
);

app.post(
  "/registerL2",
  [
    body("name")
      .isLowercase()
      .withMessage("Name must be a lowercase string")
      .isFQDN()
      .withMessage("Name must be a fully qualified domain name")
      .custom((name) => {
        const [sub, domain, tld] = name.split(".");
        if (![`${clickNSDomain}.${parentTLD}`, `${nodleNSDomain}.${parentTLD}`].includes(`${domain}.${tld}`)) {
          return false;
        }

        const subHash = keccak256(toUtf8Bytes(sub));
        if (reservedHashes.includes(subHash)) {
          return false;
        }

        return true;
      })
      .withMessage("Invalid domain or tld or reserved subdomain"),
    body("owner")
      .isString()
      .custom((owner) => {
        return isAddress(owner);
      })
      .withMessage("Owner must be a valid Ethereum address"),
  ],
  async (req: Request, res: Response) => {
    try {
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
      const decodedToken = await admin.auth().verifyIdToken(idToken, true);
      if (!decodedToken.email_verified) {
        res.status(403).json({ error: "Email not verified" });
        return;
      }
      if (decodedToken.subDomain) {
        res.status(403).json({
          error: "One subdomain already claimed with this email address",
        });
        return;
      }

      const result = validationResult(req);
      if (!result.isEmpty()) {
        res.status(400).json(result.array());
        return;
      }
      const data = matchedData(req);
      const [name,sub] = data.name.split(".");
      if (sub.length < 5) {
        throw new Error(
          "Current available subdomain names are limited to those with at least 5 characters"
        );
      }
      const owner = getAddress(data.owner);

      let response;
      if (zyfiSponsoredUrl) {
        const zyfiRequest = buildZyfiRegisterRequest(owner, name, sub);
        const zyfiResponse = await fetchZyfiSponsored(zyfiRequest);
        console.log(`ZyFi response: ${JSON.stringify(zyfiResponse)}`);

        await admin.auth().revokeRefreshTokens(decodedToken.uid);

        response = await l2Wallet.sendTransaction(zyfiResponse.txData);
      } else {
        await admin.auth().revokeRefreshTokens(decodedToken.uid);

        response = await clickNameServiceContract.register(owner, sub);
      }

      const receipt = await response.wait();
      if (receipt.status !== 1) {
        throw new Error("Transaction failed");
      }

      await admin
        .auth()
        .setCustomUserClaims(decodedToken.uid, { subDomain: sub });
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
  }
);

app.use('/name', namesRouter);

app.use((err: Error, req: Request, res: Response, next: NextFunction): void => {
  if (err instanceof HttpError) {
    res.status(err.statusCode).json({ error: err.message });
    return;
  }

  const message = err instanceof Error ? err.message : String(err);
  res.status(500).json({ error: message });
});

// Start server
app.listen(port, () => {
  console.log(`Server is running on port ${port}`);
});
