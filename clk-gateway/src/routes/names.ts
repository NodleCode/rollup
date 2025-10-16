import {
  getAddress,
  isAddress,
  isHexString,
  keccak256,
  toUtf8Bytes,
} from "ethers";
import { Router } from "express";
import { body, matchedData, validationResult } from "express-validator";
import { FIND_HANDLE_OWNERSHIP } from "../graphql";
import {
  asyncHandler,
  buildTypedData,
  fetchZyfiSponsored,
  isOffchainLookupError,
  isParsableError,
  validateSignature,
} from "../helpers";
import { CLICK_RESOLVER_INTERFACE } from "../interfaces";
import reservedHashes from "../reservedHashes";
import {
  buildZyfiRegisterRequest,
  buildZyfiSetTextRecordRequest,
  clickNameServiceContract,
  clickNSDomain,
  indexerUrl,
  l1Provider,
  l2Wallet,
  nodleNameServiceContract,
  nodleNSDomain,
  parentTLD,
  zyfiSponsoredUrl,
} from "../setup";
import { HttpError } from "../types";

const router = Router();

// POST /name/register
router.post(
  "/register",
  [
    body("name")
      .isLowercase()
      .withMessage("Name must be a lowercase string")
      .isFQDN()
      .withMessage("Name must be a fully qualified domain name")
      .custom((name) => {
        const [sub, domain, tld] = name.split(".");
        if (
          ![
            `${clickNSDomain}.${parentTLD}`,
            `${nodleNSDomain}.${parentTLD}`,
          ].includes(`${domain}.${tld}`)
        ) {
          return false;
        }

        const subHash = keccak256(toUtf8Bytes(sub));
        if (reservedHashes.includes(subHash)) {
          return false;
        }

        return true;
      })
      .withMessage("Invalid domain or tld or reserved subdomain")
      .custom((name) => {
        const [sub] = name.split(".");
        if (sub.length < 5) {
          return false;
        }
        return true;
      })
      .withMessage(
        "Current available subdomain names are limited to those with at least 5 characters",
      ),
    body("signature")
      .isString()
      .custom((signature) => {
        return isHexString(signature);
      })
      .withMessage("Signature must be a hex string"),
    body("owner")
      .isString()
      .custom((owner) => {
        return isAddress(owner);
      })
      .withMessage("Owner must be a valid Ethereum address"),
    body("email")
      .isEmail()
      .withMessage("Email must be a valid email address")
      .optional()
      .default(""),
  ],
  asyncHandler(async (req, res) => {
    // const decodedToken = await getDecodedToken(req);

    const result = validationResult(req);
    if (!result.isEmpty()) {
      throw new HttpError(
        result
          .array()
          .map((error) => error.msg)
          .join(", "),
        400,
      );
    }
    const data = matchedData(req);
    const [name, sub, tld] = data.name.split(".");
    const owner = getAddress(data.owner);

    const typedData = buildTypedData({
      name: data.name,
      email: data.email || "example@not-valid.com",
    });

    const isValidSignature = validateSignature({
      typedData,
      signature: data.signature,
      expectedSigner: owner,
    });

    if (!isValidSignature) {
      throw new HttpError("Invalid signature", 403);
    }

    let response;
    if (zyfiSponsoredUrl) {
      const zyfiRequest = buildZyfiRegisterRequest(owner, name, sub);
      const zyfiResponse = await fetchZyfiSponsored(zyfiRequest);
      console.log(`ZyFi response: ${JSON.stringify(zyfiResponse)}`);

      // await admin.auth().revokeRefreshTokens(decodedToken.uid);

      response = await l2Wallet.sendTransaction(zyfiResponse.txData);
    } else {
      // await admin.auth().revokeRefreshTokens(decodedToken.uid);

      response = await clickNameServiceContract.register(owner, sub);
    }

    const receipt = await response.wait();
    if (receipt.status !== 1) {
      throw new Error("Transaction failed");
    }

    /* await admin
      .auth()
      .setCustomUserClaims(decodedToken.uid, { subDomain: sub }); */
    res.status(200).send({
      txHash: receipt.hash,
      name: `${name}.${sub}.${tld}`,
    });
  }),
);

// POST /name/set-text-record
router.post(
  "/set-text-record",
  [
    body("name")
      .isLowercase()
      .withMessage("Name must be a lowercase string")
      .isFQDN()
      .withMessage("Name must be a fully qualified domain name")
      .custom((name) => {
        const [sub, domain, tld] = name.split(".");
        if (
          ![
            `${clickNSDomain}.${parentTLD}`,
            `${nodleNSDomain}.${parentTLD}`,
          ].includes(`${domain}.${tld}`)
        ) {
          return false;
        }

        const subHash = keccak256(toUtf8Bytes(sub));
        if (reservedHashes.includes(subHash)) {
          return false;
        }

        return true;
      })
      .withMessage("Invalid domain or tld or reserved subdomain")
      .custom((name) => {
        const [sub] = name.split(".");
        if (sub.length < 5) {
          return false;
        }
        return true;
      })
      .withMessage(
        "Current available subdomain names are limited to those with at least 5 characters",
      ),
    body("key")
      .isString()
      .isLength({ min: 4, max: 20 })
      .withMessage("Key must be between 4 and 20 characters"),
    body("value")
      .isString()
      .isLength({ min: 1, max: 256 })
      .withMessage("Value must be between 1 and 256 characters"),
    body("owner")
      .custom((owner) => {
        return isAddress(owner);
      })
      .withMessage("Owner must be a valid Ethereum address"),
    body("signature")
      .isString()
      .custom((signature) => {
        return isHexString(signature);
      })
      .withMessage("Signature must be a hex string"),
  ],
  asyncHandler(async (req, res) => {
    const result = validationResult(req);
    if (!result.isEmpty()) {
      throw new HttpError(
        result
          .array()
          .map((error) => error.msg)
          .join(", "),
        400,
      );
    }
    const data = matchedData(req);
    const [name, sub] = data.name.split(".");
    const owner = getAddress(data.owner);

    const typedData = buildTypedData(
      {
        name: data.name,
        key: data.key,
        value: data.value,
      },
      {
        TextRecord: [
          {
            name: "name",
            type: "string",
          },
          {
            name: "key",
            type: "string",
          },
          {
            name: "value",
            type: "string",
          },
        ],
      },
    );

    const isValidSignature = validateSignature({
      typedData,
      signature: data.signature,
      expectedSigner: owner,
    });

    if (!isValidSignature) {
      throw new HttpError("Invalid signature", 403);
    }

    let response;
    if (zyfiSponsoredUrl) {
      const zyfiRequest = buildZyfiSetTextRecordRequest(
        name,
        sub,
        data.key,
        data.value,
      );
      const zyfiResponse = await fetchZyfiSponsored(zyfiRequest);
      console.log(`ZyFi response: ${JSON.stringify(zyfiResponse)}`);

      response = await l2Wallet.sendTransaction(zyfiResponse.txData);
    } else {
      response = await clickNameServiceContract.setTextRecord(
        name,
        data.key,
        data.value,
      );
    }

    const receipt = await response.wait();
    if (receipt.status !== 1) {
      throw new Error("Transaction failed");
    }

    res.status(200).send({
      txHash: receipt.hash,
      key: data.key,
      value: data.value,
    });
  }),
);

// POST /name/set-text-record/message
router.post(
  "/set-text-record/message",
  [
    body("name")
      .isLowercase()
      .withMessage("Name must be a lowercase string")
      .isFQDN()
      .withMessage("Name must be a fully qualified domain name")
      .custom((name) => {
        const [sub, domain, tld] = name.split(".");
        if (
          ![
            `${clickNSDomain}.${parentTLD}`,
            `${nodleNSDomain}.${parentTLD}`,
          ].includes(`${domain}.${tld}`)
        ) {
          return false;
        }

        const subHash = keccak256(toUtf8Bytes(sub));
        if (reservedHashes.includes(subHash)) {
          return false;
        }

        return true;
      })
      .withMessage("Invalid domain or tld or reserved subdomain")
      .custom((name) => {
        const [sub] = name.split(".");
        if (sub.length < 5) {
          return false;
        }
        return true;
      })
      .withMessage(
        "Current available subdomain names are limited to those with at least 5 characters",
      ),
    body("key")
      .isString()
      .isLength({ min: 4, max: 20 })
      .withMessage("Key must be between 4 and 20 characters"),
    body("value")
      .isString()
      .isLength({ min: 1, max: 256 })
      .withMessage("Value must be between 1 and 256 characters"),
    body("owner"),
  ],
  asyncHandler(async (req, res) => {
    const result = validationResult(req);
    if (!result.isEmpty()) {
      throw new HttpError(
        result
          .array()
          .map((error) => error.msg)
          .join(", "),
        400,
      );
    }
    const data = matchedData(req);

    const typedData = buildTypedData(
      {
        name: data.name,
        key: data.key,
        value: data.value,
      },
      {
        TextRecord: [
          {
            name: "name",
            type: "string",
          },
          {
            name: "key",
            type: "string",
          },
          {
            name: "value",
            type: "string",
          },
        ],
      },
    );
    res.status(200).send(typedData);
  }),
);

// POST /name/register/message
router.post(
  "/register/message",
  [
    body("name")
      .isLowercase()
      .withMessage("Name must be a lowercase string")
      .isFQDN()
      .withMessage("Name must be a fully qualified domain name")
      .custom((name) => {
        const [sub, domain, tld] = name.split(".");
        if (
          ![
            `${clickNSDomain}.${parentTLD}`,
            `${nodleNSDomain}.${parentTLD}`,
          ].includes(`${domain}.${tld}`)
        ) {
          return false;
        }

        const subHash = keccak256(toUtf8Bytes(sub));
        if (reservedHashes.includes(subHash)) {
          return false;
        }

        return true;
      })
      .withMessage("Invalid domain or tld or reserved subdomain")
      .custom((name) => {
        const [sub] = name.split(".");
        if (sub.length < 5) {
          return false;
        }
        return true;
      })
      .withMessage(
        "Current available subdomain names are limited to those with at least 5 characters",
      ),
    body("email")
      .isEmail()
      .withMessage("Email must be a valid email address")
      .optional()
      .default(""),
  ],
  asyncHandler(async (req, res) => {
    // await checkUserByEmail(req);
    const result = validationResult(req);
    if (!result.isEmpty()) {
      throw new HttpError(
        result
          .array()
          .map((error) => error.msg)
          .join(", "),
        400,
      );
    }
    const data = matchedData(req);

    const typedData = buildTypedData({
      name: data.name,
      email: data.email || "example@not-valid.com",
    });

    res.status(200).send(typedData);
  }),
);

// POST /name/resolve
router.post(
  "/resolve",
  body("name")
    .isFQDN()
    .withMessage("Name must be a fully qualified domain name")
    .custom((name) => {
      const [sub, domain, tld] = name.split(".");
      if (
        tld === undefined &&
        ![
          `${clickNSDomain}.${parentTLD}`,
          `${nodleNSDomain}.${parentTLD}`,
        ].includes(`${domain}.${tld}`)
      ) {
        return false;
      }
      return true;
    })
    .withMessage("Invalid domain or tld"),
  async (req, res) => {
    try {
      const result = validationResult(req);
      if (!result.isEmpty()) {
        throw new HttpError(
          result
            .array()
            .map((error) => error.msg)
            .join(", "),
          400,
        );
      }
      const name = matchedData(req).name;

      const parts = name.split(".");
      const [sub, domain] = parts;

      let owner;
      if (domain === clickNSDomain) {
        owner = await clickNameServiceContract.resolve(sub);
      } else if (domain === nodleNSDomain) {
        owner = await nodleNameServiceContract.resolve(sub);
      } else {
        owner = await l1Provider.resolveName(name);
      }

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

      throw error;
    }
  },
);

// POST /name/validate-handle
router.post(
  "/validate-handle",
  [
    body("name")
      .isLowercase()
      .withMessage("Name must be a lowercase string")
      .isFQDN()
      .withMessage("Name must be a fully qualified domain name")
      .custom((name) => {
        const [sub, domain, tld] = name.split(".");
        if (
          ![
            `${clickNSDomain}.${parentTLD}`,
            `${nodleNSDomain}.${parentTLD}`,
          ].includes(`${domain}.${tld}`)
        ) {
          return false;
        }

        const subHash = keccak256(toUtf8Bytes(sub));
        if (reservedHashes.includes(subHash)) {
          return false;
        }

        return true;
      })
      .withMessage("Invalid domain or tld or reserved subdomain")
      .custom((name) => {
        const [sub] = name.split(".");
        if (sub.length < 5) {
          return false;
        }
        return true;
      })
      .withMessage(
        "Current available subdomain names are limited to those with at least 5 characters",
      ),
    body("service")
      .isString()
      .isLength({ min: 4, max: 20 })
      .withMessage("Key must be between 4 and 20 characters")
      .isIn(["com.twitter", "com.x"])
      .withMessage("Unsupported service"),
    body("handle")
      .isString()
      .isLength({ min: 1, max: 256 })
      .withMessage("Value must be between 1 and 256 characters"),
  ],
  asyncHandler(async (req, res) => {
    const result = validationResult(req);
    if (!result.isEmpty()) {
      throw new HttpError(
        result
          .array()
          .map((error) => error.msg)
          .join(", "),
        400,
      );
    }
    const requestData = matchedData(req);

    const query = FIND_HANDLE_OWNERSHIP(
      requestData.name,
      requestData.handle,
      requestData.service,
    );

    const response = await fetch(indexerUrl, {
      method: "POST",
      body: JSON.stringify({ query }),
      headers: {
        "Content-Type": "application/json",
      },
      redirect: "follow",
    });

    const responseData = await response.json();

    if (!response.ok) {
      console.error("Indexer response error:", responseData);
      throw new HttpError("Failed to validate handle", 500);
    }

    const nodes = responseData?.data?.eNs?.nodes || [];
    if (nodes.length === 0) {
      // ENS name not found
      res.status(200).send({ owned: false });
      return;
    }

    const textRecords = nodes[0]?.textRecords?.nodes || [];
    if (textRecords.length === 0) {
      // No text records found
      res.status(200).send({ owned: false });
      return;
    }

    res.status(200).send({ owned: true });
  }),
);

export default router;
