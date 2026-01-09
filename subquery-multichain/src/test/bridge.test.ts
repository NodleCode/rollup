import { subqlTest } from "@subql/testing";
import { ethers } from "ethers";

/**
 * Unit tests for Bridge mapping handlers
 * 
 * These tests use SubQuery's testing framework to verify that handlers
 * correctly process events and create/update entities in the database.
 * 
 * Run tests with: npm test
 */

describe("Bridge Mappings", () => {
  describe("handleDepositFinalized (L2)", () => {
    it("should create a new BridgeDeposit when deposit is finalized on L2", async () => {
      const expectedDeposit = {
        id: "deposit-0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        l2TransactionHash: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        amount: "1000000000000000000",
      };

      await subqlTest(
        "handleDepositFinalized - creates new deposit",
        65260492, // L2 block number
        [], // no dependencies
        [expectedDeposit], // expected entities
        "handleDepositFinalized" // handler name
      );
    });
  });

  describe("handleWithdrawalInitiated (L2)", () => {
    it("should create a new BridgeWithdrawal when withdrawal is initiated on L2", async () => {
      const expectedWithdrawal = {
        id: "0x1111111111111111111111111111111111111111111111111111111111111111",
        status: "initiated",
        l2TransactionHash: "0x1111111111111111111111111111111111111111111111111111111111111111",
        amount: "500000000000000000",
        l2BlockNumber: "65260493",
      };

      await subqlTest(
        "handleWithdrawalInitiated - creates new withdrawal",
        65260493, // L2 block number
        [], // no dependencies
        [expectedWithdrawal], // expected entities
        "handleWithdrawalInitiated" // handler name
      );
    });
  });

  describe("handleWithdrawalFinalized (L1)", () => {
    it("should update existing withdrawal when finalized on L1", async () => {
      const l2TxHash =
        "0x1111111111111111111111111111111111111111111111111111111111111111";

      // Existing withdrawal created on L2 (dependency)
      const existingWithdrawal = {
        id: l2TxHash,
        status: "initiated",
        l2TransactionHash: l2TxHash,
        amount: "500000000000000000",
        l2BlockNumber: "65260493",
        receiverId: "0x2222222222222222222222222222222222222222", // Required for store.getByFields query
      };

      // Expected withdrawal after L1 finalization
      const expectedWithdrawal = {
        id: l2TxHash,
        status: "finalized",
        l2TransactionHash: l2TxHash,
        amount: "500000000000000000",
        l2BlockNumber: "65260493",
        receiverId: "0x2222222222222222222222222222222222222222", // Required field
        batchNumber: "503366",
        messageIndex: "17",
        txNumberInBatch: "1025",
        finalizedAt: "1704067400000",
      };

      await subqlTest(
        "handleWithdrawalFinalized - updates existing withdrawal",
        23635689, // L1 block number
        [existingWithdrawal], // dependencies
        [expectedWithdrawal], // expected entities
        "handleWithdrawalFinalized" // handler name
      );
    });

    // Note: Testing error case where withdrawal is not found is complex
    // because it requires mocking RPC calls and store.getByFields.
    // This scenario should be handled in integration tests or E2E tests.
  });

  describe("handleDepositInitiated (L1)", () => {
    it("should create a new BridgeDeposit when deposit is initiated on L1", async () => {
      const expectedDeposit = {
        id: "deposit-0x4444444444444444444444444444444444444444444444444444444444444444",
        amount: "2000000000000000000",
      };

      await subqlTest(
        "handleDepositInitiated - creates new deposit",
        23635846, // L1 block number
        [], // no dependencies
        [expectedDeposit], // expected entities
        "handleDepositInitiated" // handler name
      );
    });
  });

  describe("handleClaimedFailedDeposit (L1)", () => {
    it("should create a new BridgeFailedDepositClaim when failed deposit is claimed", async () => {
      const expectedClaim = {
        id: "0x5555555555555555555555555555555555555555555555555555555555555555",
        amount: "1500000000000000000",
      };

      await subqlTest(
        "handleClaimedFailedDeposit - creates new claim",
        23635847, // L1 block number
        [], // no dependencies
        [expectedClaim], // expected entities
        "handleClaimedFailedDeposit" // handler name
      );
    });
  });
});

