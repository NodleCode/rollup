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
 * Get L2 transaction hash by batch number and transaction index
 * Follows the logic from the Python script:
 * 1. Get block range for the batch
 * 2. Iterate through blocks to find where the index lands
 * 3. Get the transaction hash by block number and relative index
 */
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
    }

    let currentOffset = 0;
    const checkedBlocks = new Set<number>();

    // 2a. First, check possible blocks if provided
    if (possibleBlocksInRange.length > 0) {
      for (let blockNum = startBlock; blockNum <= endBlock; blockNum++) {
        const blockHex = `0x${blockNum.toString(16).toLowerCase()}`;
        const txCountHex = await rpcCall(
          "eth_getBlockTransactionCountByNumber",
          [blockHex],
          rpcUrl,
          retries
        );
        const txCount = parseInt(txCountHex, 16);

        // If this is a possible block, check it first
        if (possibleBlocksInRange.includes(blockNum)) {
          logger.debug(
            `Checking possible block ${blockNum} (${blockHex}): ${txCount} transactions, currentOffset: ${currentOffset}, targetIndex: ${txIndex}`
          );

          // Check if our target index falls within this block's range
          if (currentOffset + txCount > txIndex) {
            const relativeIndex = txIndex - currentOffset;
            logger.info(
              `Match found in possible L2 Block ${blockNum} (Hex: ${blockHex}), relative index: ${relativeIndex}`
            );

            // Fetch the specific transaction hash
            const indexHex = `0x${relativeIndex.toString(16).toLowerCase()}`;
            const tx = await rpcCall(
              "eth_getTransactionByBlockNumberAndIndex",
              [blockHex, indexHex],
              rpcUrl,
              retries
            );

            if (tx && tx.hash) {
              logger.info(
                `Found transaction hash: ${tx.hash} at possible block ${blockNum}, index ${relativeIndex}`
              );
              return tx.hash;
            }
          }
        }

        currentOffset += txCount;
        checkedBlocks.add(blockNum);
      }

      // If found in possible blocks, we would have returned already
      // Reset offset for normal iteration
      currentOffset = 0;
    }

    // 2b. If not found in possible blocks, continue with normal iteration
    for (let blockNum = startBlock; blockNum <= endBlock; blockNum++) {
      if (checkedBlocks.has(blockNum)) {
        // Skip already checked blocks, but update offset
        const blockHex = `0x${blockNum.toString(16).toLowerCase()}`;
        const txCountHex = await rpcCall(
          "eth_getBlockTransactionCountByNumber",
          [blockHex],
          rpcUrl,
          retries
        );
        const txCount = parseInt(txCountHex, 16);
        currentOffset += txCount;
        continue;
      }
      // Format block number as hex (same as Python's hex() function)
      const blockHex = `0x${blockNum.toString(16)}`;

      // Get count of transactions in this specific block
      const txCountHex = await rpcCall(
        "eth_getBlockTransactionCountByNumber",
        [blockHex],
        rpcUrl,
        retries
      );
      const txCount = parseInt(txCountHex, 16);

      logger.debug(
        `Block ${blockNum} (${blockHex}): ${txCount} transactions, currentOffset: ${currentOffset}, targetIndex: ${txIndex}`
      );

      // Check if our target index falls within this block's range
      if (currentOffset + txCount > txIndex) {
        const relativeIndex = txIndex - currentOffset;
        logger.info(
          `Match found in L2 Block ${blockNum} (Hex: ${blockHex}), relative index: ${relativeIndex}`
        );

        // 3. Fetch the specific transaction hash
        // Format index as hex (same as Python's hex() function)
        // Ensure lowercase hex like Python's hex() function
        const indexHex = `0x${relativeIndex.toString(16).toLowerCase()}`;
        logger.debug(
          `Fetching transaction at block ${blockHex}, index ${indexHex} (relative: ${relativeIndex})`
        );
        const tx = await rpcCall(
          "eth_getTransactionByBlockNumberAndIndex",
          [blockHex, indexHex],
          rpcUrl,
          retries
        );

        if (tx && tx.hash) {
          logger.info(
            `Found transaction hash: ${tx.hash} at block ${blockNum}, index ${relativeIndex}`
          );
          return tx.hash;
        } else {
          logger.warn(
            `Transaction not found at block ${blockNum}, index ${relativeIndex}. TX response: ${JSON.stringify(
              tx
            )}`
          );
          return null;
        }
      }

      currentOffset += txCount;
    }

    logger.warn(
      `Transaction index ${txIndex} out of range for batch ${batchNumber}. Total transactions processed: ${currentOffset}`
    );
    return null;
  } catch (error) {
    logger.warn(
      `Failed to get L2 transaction hash for batch ${batchNumber}, index ${txIndex}: ${error}`
    );
    return null;
  }
}

