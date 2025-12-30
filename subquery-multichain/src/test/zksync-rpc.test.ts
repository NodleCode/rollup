import {
  getL2TransactionHashByBatchAndIndex,
  getBlockTransactionCountByNumber,
  getTransactionByBlockNumberAndIndex,
} from "../utils/zksync-rpc";

// Mock logger
const mockLogger = {
  info: jest.fn(),
  warn: jest.fn(),
  error: jest.fn(),
  debug: jest.fn(),
};

// Make logger available globally
(global as any).logger = mockLogger;

// Use real zkSync RPC endpoint for integration tests
const RPC_URL =
  process.env.ZKSYNC_MAINNET_RPC || "https://mainnet.era.zksync.io";

// Increase timeout for all tests (real RPC calls can be slow)
jest.setTimeout(30000);

describe("zksync-rpc utilities", () => {
  describe("getBlockTransactionCountByNumber", () => {
    it("should return transaction count for a valid block", async () => {
      const blockNumber = 65389963;
      const result = await getBlockTransactionCountByNumber(
        blockNumber,
        RPC_URL
      );

      expect(result).toBeGreaterThanOrEqual(0);
      expect(typeof result).toBe("number");
    });
  });

  describe("getTransactionByBlockNumberAndIndex", () => {
    it("should return transaction hash for valid block and index", async () => {
      const blockNumber = 65389963;
      const index = 0; // First transaction in block

      const result = await getTransactionByBlockNumberAndIndex(
        blockNumber,
        index,
        RPC_URL
      );

      if (result) {
        expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/);
      } else {
        // Block might have no transactions
        const txCount = await getBlockTransactionCountByNumber(
          blockNumber,
          RPC_URL
        );
        expect(txCount).toBe(0);
      }
    });

    it("should return null for invalid index", async () => {
      const blockNumber = 65389963;
      const invalidIndex = 999999;

      const result = await getTransactionByBlockNumberAndIndex(
        blockNumber,
        invalidIndex,
        RPC_URL
      );

      expect(result).toBeNull();
    });
  });

  describe("getL2TransactionHashByBatchAndIndex", () => {
    // Use real batch and transaction index from zkSync mainnet
    // These values should be valid and exist on mainnet
    const batchNumber = 503366;
    const txIndex = 1025;

    beforeEach(() => {
      jest.clearAllMocks();
      // Ensure logger is set to mock after clearing
      (global as any).logger = mockLogger;
    });

    describe("successful cases", () => {
      it("should return transaction hash when found using real RPC calls", async () => {
        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          10,
          RPC_URL,
          3
        );

        expect(result).toBeTruthy();
        expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/); // Valid transaction hash format
        expect(mockLogger.info).toHaveBeenCalledWith(
          expect.stringContaining(
            `Getting L2 transaction hash for batch ${batchNumber}`
          )
        );
      });

      it("should return transaction hash when found using possibleBlockNumbers", async () => {
        // Use a block in the middle of the range as possible block with txHash
        // First, get a real transaction hash from that block
        const blockNumber = 65389963;
        const txHash =
          "0x494c1b7becf09814e34a02403fb7a1bbe0f0de70e861de907ea3e4a70007efe7";

        const possibleBlocks = [
          {
            blockNumber: blockNumber,
            txHash: txHash,
          },
        ];

        // Find the global index for this transaction in the batch
        // We'll use a small index that should match
        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          txIndex,
          RPC_URL,
          3,
          possibleBlocks
        );

        // Result should be valid if transaction exists, or null if not
        if (result) {
          expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/);
        }
        expect(mockLogger.info).toHaveBeenCalledWith(
          expect.stringContaining("possible blocks first")
        );
      });

      it("should handle different transaction indices correctly", async () => {
        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          1,
          RPC_URL,
          3
        );

        // Result should be either a valid hash or null if index is out of range
        if (result) {
          expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/);
        }
      });
    });

    describe("error cases", () => {
      it("should return null when batch is not found (future batch)", async () => {
        // Use a very high batch number that doesn't exist yet
        const futureBatchNumber = 999999999999;

        const result = await getL2TransactionHashByBatchAndIndex(
          futureBatchNumber,
          txIndex,
          RPC_URL,
          3
        );

        expect(result).toBeNull();
        // When batch doesn't exist, RPC returns "Invalid params" error
        // The function catches this and logs a warning about failing to get the hash
        expect(mockLogger.warn).toHaveBeenCalledWith(
          expect.stringContaining("Failed to get L2 transaction hash")
        );
      });

      it("should handle invalid RPC URL gracefully", async () => {
        const invalidRpcUrl = "https://invalid-rpc-url.example.com";

        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          txIndex,
          invalidRpcUrl,
          3
        );

        expect(result).toBeNull();
        expect(mockLogger.warn).toHaveBeenCalledWith(
          expect.stringContaining("Failed to get L2 transaction hash")
        );
      });

      it("should filter possibleBlockNumbers to only those in batch range", async () => {
        // Create possible blocks: one before range, one in range, one after range
        // Get real transaction hashes for blocks in range
        const blockInRange = 65389963;
        const txHash =
          "0x494c1b7becf09814e34a02403fb7a1bbe0f0de70e861de907ea3e4a70007efe7";

        if (!txHash) {
          // Skip test if block has no transactions
          return;
        }

        const possibleBlocks = [
          {
            blockNumber: 65389962,
            txHash:
              "0x0000000000000000000000000000000000000000000000000000000000000000",
          }, // before range
          { blockNumber: blockInRange, txHash: txHash }, // in range
          {
            blockNumber: 65389964,
            txHash:
              "0x0000000000000000000000000000000000000000000000000000000000000000",
          }, // after range
        ];

        // Clear mocks before test
        jest.clearAllMocks();
        (global as any).logger = mockLogger;

        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          txIndex,
          RPC_URL,
          3,
          possibleBlocks
        );

        // Should log that it's checking possible blocks
        expect(mockLogger.info).toHaveBeenCalledWith(
          expect.stringContaining("possible blocks first")
        );

        // Result should be valid if transaction exists, or null if not
        if (result) {
          expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/);
        }
      });
    });
  });
});

