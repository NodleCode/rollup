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

/**
 * Helper function to make batch RPC calls
 * Accepts an array of requests and returns an array of results in the same order
 */
async function rpcBatchCall(
  requests: Array<{ method: string; params: any[] }>,
  rpcUrl: string,
  retries: number = 3
): Promise<any[]> {
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const payload = requests.map((req, index) => ({
        jsonrpc: "2.0",
        method: req.method,
        params: req.params,
        id: index + 1,
      }));

      const response = await fetch(rpcUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });

      const responseData = await response.json();

      // Handle both single response object and array of responses
      const responses = Array.isArray(responseData) ? responseData : [responseData];

      // Check for errors in any response
      for (const resp of responses) {
        if (resp?.error) {
          throw new Error(
            `RPC batch error: ${
              resp.error.message || JSON.stringify(resp.error)
            }`
          );
        }
      }

      // Sort responses by id to maintain order
      const sortedResponses = responses.sort((a, b) => (a.id || 0) - (b.id || 0));
      return sortedResponses.map((resp) => resp.result);
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      if (attempt < retries) {
        logger.warn(
          `Attempt ${attempt}/${retries} failed for RPC batch call, retrying...`
        );
        await new Promise((resolve) =>
          setTimeout(resolve, Math.pow(2, attempt - 1) * 1000)
        );
      }
    }
  }

  throw (
    lastError || new Error(`Failed to call batch RPC after ${retries} attempts`)
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

/**
 * Get transaction counts for multiple blocks in batch RPC calls
 * This is much more efficient than calling getBlockTransactionCountByNumber multiple times
 * Splits into chunks to avoid RPC provider limits (typically 100-200 requests per batch)
 */
export async function getBlockTransactionCountsByNumbers(
  blockNumbers: number[],
  rpcUrl: string,
  chunkSize: number = 100
): Promise<number[]> {
  if (blockNumbers.length === 0) {
    return [];
  }

  const results: number[] = [];

  // Split into chunks to avoid RPC provider limits
  for (let i = 0; i < blockNumbers.length; i += chunkSize) {
    const chunk = blockNumbers.slice(i, i + chunkSize);
    const requests = chunk.map((blockNumber) => {
      const blockHex = `0x${blockNumber.toString(16).toLowerCase()}`;
      return {
        method: "eth_getBlockTransactionCountByNumber",
        params: [blockHex],
      };
    });

    const chunkResults = await rpcBatchCall(requests, rpcUrl);
    const parsedResults = chunkResults.map((txCountHex: string) =>
      parseInt(txCountHex, 16)
    );
    results.push(...parsedResults);
  }

  return results;
}

/* Helper function to get transaction by block number and index */
export async function getTransactionByBlockNumberAndIndex(
  blockNumber: number,
  index: number,
  rpcUrl: string
): Promise<string | null> {
  const blockHex = `0x${blockNumber.toString(16).toLowerCase()}`;
  const indexHex = `0x${index.toString(16).toLowerCase()}`;
  logger.info(
    `Getting transaction by block number ${blockNumber} and index ${index}`
  );
  const tx = await rpcCall(
    "eth_getTransactionByBlockNumberAndIndex",
    [blockHex, indexHex],
    rpcUrl
  );
  return tx?.hash || null;
}

export async function getL2TransactionHashByBatchAndIndex(
  batchNumber: number,
  txIndex: number,
  rpcUrl: string,
  retries: number = 3
): Promise<string | null> {
  try {
    logger.info(
      `Getting L2 transaction hash for batch ${batchNumber}, index ${txIndex}`
    );

    // Note: zkSync does not provide a direct RPC method to get transaction by batch and index
    // zks_getL1BatchDetails only returns metadata (l1TxCount, l2TxCount) but not transaction hashes
    // We must use zks_getL1BatchBlockRange + eth_getTransactionByBlockNumberAndIndex

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

    // Get all block numbers in the batch range
    const totalBlocks = endBlock - startBlock + 1;
    const allBlockNumbers: number[] = [];
    for (let blockNum = startBlock; blockNum <= endBlock; blockNum++) {
      allBlockNumbers.push(blockNum);
    }

    logger.info(
      `Getting transaction counts for all ${totalBlocks} blocks in batch ${batchNumber} using batch RPC (will split into chunks if needed)`
    );

    // Get all transaction counts in batch RPC calls (split into chunks to avoid RPC limits)
    const txCounts = await getBlockTransactionCountsByNumbers(
      allBlockNumbers,
      rpcUrl,
      100 // Chunk size: most RPC providers limit batch requests to 100-200
    );

    if (!txCounts || txCounts.length !== allBlockNumbers.length) {
      logger.warn(
        `Failed to get transaction counts for all blocks. Expected ${
          allBlockNumbers.length
        }, got ${txCounts?.length || 0}`
      );
      return null;
    }

    // Calculate total transactions in batch
    const totalTransactions = txCounts.reduce((sum, count) => sum + count, 0);
    logger.info(
      `Batch ${batchNumber} has ${totalTransactions} total transactions across ${allBlockNumbers.length} blocks`
    );

    if (totalTransactions === 0) {
      logger.warn(`Batch ${batchNumber} has no transactions`);
      return null;
    }

    if (txIndex >= totalTransactions) {
      logger.warn(
        `Transaction index ${txIndex} out of range for batch ${batchNumber}. Total transactions: ${totalTransactions}`
      );
      return null;
    }

    // Iterate through all blocks and calculate cumulative offset
    let cumulativeOffset = 0;
    for (let i = 0; i < allBlockNumbers.length; i++) {
      const blockNumber = allBlockNumbers[i];
      const txCount = txCounts[i];

      // Check if our target txIndex falls within this block's range
      if (txIndex >= cumulativeOffset && txIndex < cumulativeOffset + txCount) {
        // This block contains our target index
        const relativeIndex = txIndex - cumulativeOffset;
        logger.info(
          `Target txIndex ${txIndex} found in block ${blockNumber} at relative index ${relativeIndex}`
        );

        const txHash = await getTransactionByBlockNumberAndIndex(
          blockNumber,
          relativeIndex,
          rpcUrl
        );

        if (!txHash) {
          logger.warn(
            `Failed to get transaction hash for block ${blockNumber} at index ${relativeIndex}`
          );
          cumulativeOffset += txCount;
          continue;
        }

        logger.info(
          `Found transaction hash ${txHash} in block ${blockNumber} at relative index ${relativeIndex} (batch index ${txIndex})`
        );
        return txHash;
      }

      cumulativeOffset += txCount;
    }

    logger.warn(
      `Transaction index ${txIndex} out of range for batch ${batchNumber}. Total transactions processed: ${cumulativeOffset}`
    );

    return null;
  } catch (error) {
    logger.warn(
      `Failed to get L2 transaction hash for batch ${batchNumber}, index ${txIndex}: ${error}`
    );

    return null;
  }
}

