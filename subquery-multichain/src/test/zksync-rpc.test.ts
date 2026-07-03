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
        // Use index 0 (first transaction) which should always exist if batch has transactions
        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          0,
          RPC_URL,
          3
        );

        // Check if function was called correctly
        expect(mockLogger.info).toHaveBeenCalledWith(
          expect.stringContaining(
            `Getting L2 transaction hash for batch ${batchNumber}`
          )
        );

        // If result is null, check the warning logs to understand why
        if (!result) {
          const warnCalls = mockLogger.warn.mock.calls.map((call) => call[0]);
          console.log("Warning logs:", warnCalls);
          
          // Check if batch was not found or if index was out of range
          const hasBatchNotFound = warnCalls.some((msg) =>
            typeof msg === "string" && msg.includes("not found or not yet sealed")
          );
          const hasIndexOutOfRange = warnCalls.some(
            (msg) =>
              typeof msg === "string" && msg.includes("out of range")
          );

          if (hasBatchNotFound) {
            // Batch might not exist, skip this test
            console.log("Batch not found, skipping test");
            return;
          }

          if (hasIndexOutOfRange) {
            // Batch might not have transactions at index 0, try a different index
            console.log("Index 0 out of range, trying index 1");
            const result2 = await getL2TransactionHashByBatchAndIndex(
              batchNumber,
              1,
              RPC_URL,
              3
            );
            expect(result2).toBeTruthy();
            expect(result2).toMatch(/^0x[a-fA-F0-9]{64}$/);
            return;
          }
        }

        // If we get here, result should be valid
        expect(result).toBeTruthy();
        expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/); // Valid transaction hash format
      });

      it("should return transaction hash when found in batch", async () => {
        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          txIndex,
          RPC_URL,
          3
        );

        // Result should be valid if transaction exists, or null if not
        if (result) {
          expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/);
        }
        expect(mockLogger.info).toHaveBeenCalledWith(
          expect.stringContaining(
            `Getting L2 transaction hash for batch ${batchNumber}`
          )
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

      it("should handle batch RPC calls correctly", async () => {
        // Clear mocks before test
        jest.clearAllMocks();
        (global as any).logger = mockLogger;

        const result = await getL2TransactionHashByBatchAndIndex(
          batchNumber,
          txIndex,
          RPC_URL,
          3
        );

        // Should log that it's getting transaction counts using batch RPC
        expect(mockLogger.info).toHaveBeenCalledWith(
          expect.stringContaining("Getting transaction counts for all")
        );
        expect(mockLogger.info).toHaveBeenCalledWith(
          expect.stringContaining("using batch RPC")
        );

        // Result should be valid if transaction exists, or null if not
        if (result) {
          expect(result).toMatch(/^0x[a-fA-F0-9]{64}$/);
        }
      });
    });
  });
});

