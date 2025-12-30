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
  retries: number = 3,
  possibleBlockNumbers: {
    blockNumber: number;
    txHash: string;
  }[] = []
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
      .filter(
        (block) =>
          block.blockNumber >= startBlock && block.blockNumber <= endBlock
      )
      .sort((a, b) => a.blockNumber - b.blockNumber);

    if (possibleBlocksInRange.length > 0) {
      logger.info(
        `Checking ${
          possibleBlocksInRange.length
        } possible blocks first: ${possibleBlocksInRange
          .map((b) => b.blockNumber)
          .join(", ")}`
      );
      for (const block of possibleBlocksInRange) {
        const txCount = await getBlockTransactionCountByNumber(
          block.blockNumber,
          rpcUrl
        );
        for (let i = 0; i < txCount; i++) {
          const txHash = await getTransactionByBlockNumberAndIndex(
            block.blockNumber,
            i,
            rpcUrl
          );
          if (txHash === block.txHash) {
            logger.info(
              `Found transaction hash ${txHash} in block ${block.blockNumber} at index ${i}`
            );
            return txHash;
          }
        }
      }
    }

    // If not found in possible blocks, continue with normal sequential search
    let currentOffset = 0;
    for (let blockNum = startBlock; blockNum <= endBlock; blockNum++) {
      // Get count of transactions in this specific block
      const txCount = await getBlockTransactionCountByNumber(blockNum, rpcUrl);

      // Check if our target index falls within this block's range
      if (currentOffset + txCount > txIndex) {
        const relativeIndex = txIndex - currentOffset;
        logger.info(
          `Checking block ${blockNum} at index ${txIndex} - ${currentOffset} = ${relativeIndex}`
        );
        const txHash = await getTransactionByBlockNumberAndIndex(
          blockNum,
          relativeIndex,
          rpcUrl
        );
        if (txHash) {
          logger.info(
            `Found transaction hash ${txHash} in block ${blockNum} at index ${relativeIndex}`
          );
          return txHash;
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

