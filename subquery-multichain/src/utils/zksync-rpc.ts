import fetch from "node-fetch";

/**
 * Helper function to make RPC calls with retries
 */
async function rpcCall(
  method: string,
  params: any[],
  rpcUrl: string,
  retries: number = 3
): Promise<any> {
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const payload = {
        jsonrpc: "2.0",
        method: method,
        params: params,
        id: 1,
      };

      const response = await fetch(rpcUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });

      const responseData = await response.json();

      if (responseData?.error) {
        throw new Error(
          `RPC error: ${
            responseData.error.message || JSON.stringify(responseData.error)
          }`
        );
      }

      return responseData?.result;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (attempt < retries) {
        logger.warn(
          `Attempt ${attempt}/${retries} failed for RPC call ${method}, retrying...`
        );
        await new Promise((resolve) =>
          setTimeout(resolve, Math.pow(2, attempt - 1) * 1000)
        );
      }
    }
  }

  throw (
    lastError || new Error(`Failed to call ${method} after ${retries} attempts`)
  );
}

/* Helper functions to get block transaction count and transaction by block number and index */
export async function getBlockTransactionCountByNumber(
  blockNumber: number,
  rpcUrl: string
): Promise<number> {
  const blockHex = `0x${blockNumber.toString(16).toLowerCase()}`;
  const txCountHex = await rpcCall("eth_getBlockTransactionCountByNumber", [blockHex], rpcUrl);
  return parseInt(txCountHex, 16);
}

/* Helper function to get transaction by block number and index */
export async function getTransactionByBlockNumberAndIndex(
  blockNumber: number,
  index: number,
  rpcUrl: string
): Promise<string | null> {
  const blockHex = `0x${blockNumber.toString(16).toLowerCase()}`;
  const indexHex = `0x${index.toString(16).toLowerCase()}`;

  const tx = await rpcCall(
    "eth_getTransactionByBlockNumberAndIndex",
    [blockHex, indexHex],
    rpcUrl
  );
  return tx?.hash || null;
}

/* Helper function to check if a block has transactions */
export async function hasTransactions(
  blockNumber: number,
  rpcUrl: string
): Promise<boolean> {
  const txCount = await getBlockTransactionCountByNumber(blockNumber, rpcUrl);
  return txCount > 0;
}

/* Helper function to get the transaction if the index is within the block */
export async function getTransactionIfIndexIsWithinBlock(
  blockNumber: number,
  index: number,
  rpcUrl: string
): Promise<string | null> {
  const txCount = await getBlockTransactionCountByNumber(blockNumber, rpcUrl);
  if (index <= txCount) {
    return getTransactionByBlockNumberAndIndex(blockNumber, index, rpcUrl);
  }
  return null;
}

export async function getL2TransactionHashByBatchAndIndex(
  batchNumber: number,
  txIndex: number,
  rpcUrl: string,
  retries: number = 3,
  possibleBlockNumbers: number[] = []
): Promise<string | null> {
  try {
    logger.info(
      `Getting L2 transaction hash for batch ${batchNumber}, index ${txIndex}`
    );

    // 1. Get the range of L2 blocks in this batch
    const blockRange = await rpcCall(
      "zks_getL1BatchBlockRange",
      [batchNumber],
      rpcUrl,
      retries
    );

    if (!blockRange || !Array.isArray(blockRange) || blockRange.length !== 2) {
      logger.warn(
        `Batch ${batchNumber} not found or not yet sealed. BlockRange: ${JSON.stringify(
          blockRange
        )}`
      );
      return null;
    }

    const startBlock = parseInt(blockRange[0], 16);
    const endBlock = parseInt(blockRange[1], 16);

    logger.info(
      `Batch ${batchNumber} block range: ${blockRange[0]} (${startBlock}) to ${blockRange[1]} (${endBlock})`
    );

    // Filter possible blocks to only those within the batch range and sort them
    const possibleBlocksInRange = possibleBlockNumbers
      .filter((blockNum) => blockNum >= startBlock && blockNum <= endBlock)
      .sort((a, b) => a - b);

    if (possibleBlocksInRange.length > 0) {
      logger.info(
        `Checking ${
          possibleBlocksInRange.length
        } possible blocks first: ${possibleBlocksInRange.join(", ")}`
      );

      for (const blockNum of possibleBlocksInRange) {
        const tx = await getTransactionIfIndexIsWithinBlock(
          blockNum,
          txIndex,
          rpcUrl
        );
        if (tx) {
          return tx;
        }
      }
    }

    for (let blockNum = startBlock; blockNum <= endBlock; blockNum++) {
      if (possibleBlocksInRange.includes(blockNum)) {
        continue;
      }
      // Get count of transactions in this specific block
      const txCount = await getBlockTransactionCountByNumber(blockNum, rpcUrl);

      // Check if our target index falls within this block's range
      if (txCount >= txIndex) {
        const tx = await getTransactionIfIndexIsWithinBlock(
          blockNum,
          txIndex,
          rpcUrl
        );
        if (tx) {
          return tx;
        }
      }
    }

    return null;
  } catch (error) {
    logger.warn(
      `Failed to get L2 transaction hash for batch ${batchNumber}, index ${txIndex}: ${error}`
    );

    return null;
  }
}

