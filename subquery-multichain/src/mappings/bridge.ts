import { fetchAccount } from "../utils/utils";
import { getL2TransactionHashByBatchAndIndex } from "../utils/zksync-rpc";
import {
  BridgeWithdrawal,
  BridgeDeposit,
  BridgeFailedDepositClaim,
} from "../types";
import {
  DepositFinalizedLog,
  WithdrawalInitiatedLog,
} from "../types/abi-interfaces/BridgeL2Abi";

export async function handleDepositFinalized(
  event: DepositFinalizedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args in handleDepositFinalized");
    return;
  }

  const timestamp = BigInt(event.block.timestamp) * BigInt(1000);
  const { l1Sender, l2Receiver, amount } = event.args;

  const senderAccount = await fetchAccount(l1Sender.toLowerCase(), timestamp);
  const receiverAccount = await fetchAccount(
    l2Receiver.toLowerCase(),
    timestamp
  );

  // Use l2TransactionHash as common ID between L1 and L2
  // In L2, event.transaction.hash IS the l2TransactionHash that was emitted in L1
  const depositId = event.transaction.hash;

  // Try to find existing deposit from L1, or create new one
  let deposit = await BridgeDeposit.get(depositId);

  if (!deposit) {
    // Create new deposit if not found from L1
    deposit = new BridgeDeposit(
      depositId,
      timestamp,
      senderAccount.id,
      receiverAccount.id,
      amount.toBigInt()
    );
    deposit.l2TransactionHash = event.transaction.hash;
  } else {
    // Update existing deposit from L1 with L2 data
    // L2 data takes precedence for receiver and amount
    deposit.receiverId = receiverAccount.id;
    deposit.amount = amount.toBigInt();
    deposit.timestamp = timestamp;
    deposit.l2TransactionHash = event.transaction.hash;
  }

  return deposit.save();
}

export async function handleWithdrawalInitiated(
  event: WithdrawalInitiatedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args in handleWithdrawalInitiated");
    return;
  }

  const timestamp = BigInt(event.block.timestamp) * BigInt(1000);
  const { l2Sender, l1Receiver, amount } = event.args;

  const senderAccount = await fetchAccount(l2Sender.toLowerCase(), timestamp);
  const receiverAccount = await fetchAccount(
    l1Receiver.toLowerCase(),
    timestamp
  );

  // ID is the L2 transaction hash (unique identifier from L2)
  const withdrawalId = event.transaction.hash;
  const l2TransactionHash = event.transaction.hash;

  const withdrawal = new BridgeWithdrawal(
    withdrawalId,
    timestamp,
    senderAccount.id,
    receiverAccount.id,
    amount.toBigInt(),
    l2TransactionHash,
    "initiated", // status
    BigInt(event.block.number) // l2BlockNumber
  );

  // batchNumber and messageIndex are not available yet, will be set in L1 handler
  // Leave them as null

  return withdrawal.save();
}

// L1 Bridge Handlers
import {
  DepositInitiatedLog,
  WithdrawalFinalizedLog,
  ClaimedFailedDepositLog,
} from "../types/abi-interfaces/BridgeL1Abi";

export async function handleDepositInitiated(
  event: DepositInitiatedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args in handleDepositInitiated");
    return;
  }

  const timestamp = BigInt(event.block.timestamp) * BigInt(1000);
  const { l2DepositTxHash, from, to, amount } = event.args;

  const senderAccount = await fetchAccount(from.toLowerCase(), timestamp);
  const receiverAccount = await fetchAccount(to.toLowerCase(), timestamp);

  // Use l2TransactionHash as common ID between L1 and L2
  const depositId = l2DepositTxHash;

  // Try to find existing deposit from L2, or create new one
  let deposit = await BridgeDeposit.get(depositId);

  if (!deposit) {
    // Create new deposit if not found from L2
    deposit = new BridgeDeposit(
      depositId,
      timestamp,
      senderAccount.id,
      receiverAccount.id,
      amount.toBigInt()
    );
    deposit.l1TransactionHash = event.transaction.hash;
  } else {
    // Update existing deposit from L2 with L1 data
    // L1 data takes precedence for sender and amount
    deposit.senderId = senderAccount.id;
    deposit.amount = amount.toBigInt();
    deposit.timestamp = timestamp;
    deposit.l1TransactionHash = event.transaction.hash;
  }

  return deposit.save();
}

export async function handleWithdrawalFinalized(
  event: WithdrawalFinalizedLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args in handleWithdrawalFinalized");
    return;
  }

  const timestamp = BigInt(event.block.timestamp) * BigInt(1000);
  const { to, batchNumber, messageIndex, txNumberInBatch, amount } = event.args;

  // Convert txNumberInBatch to BigInt if it's a number
  const txNumberInBatchBigInt =
    typeof txNumberInBatch === "bigint"
      ? txNumberInBatch
      : BigInt(txNumberInBatch);

  const receiverAccount = await fetchAccount(to.toLowerCase(), timestamp);

  // Get L2 transaction hash using zks_getL1BatchBlockRange and eth_getTransactionByBlockNumberAndIndex
  // Use batchNumber and txNumberInBatch (which is the transaction index in the batch) to find the L2 transaction hash
  let l2TransactionHash: string | null = null;

  // Get initiated withdrawals for this receiver
  // Query database directly to avoid SubQuery index validation issues
  const entities = (await store.getByFields(
    "BridgeWithdrawal",
    [
      ["receiver_id" as keyof BridgeWithdrawal, "=", receiverAccount.id],
      ["status", "=", "initiated"],
    ],
    {
      limit: 100,
    }
  )) as BridgeWithdrawal[];

  if (entities.length === 0) {
    logger.error(
      `No initiated withdrawals found for receiver ${receiverAccount.id}`
    );
    throw new Error(
      `No initiated withdrawals found for receiver ${receiverAccount.id}`
    );
  }

  try {
    const rpcUrl =
      process.env.ZKSYNC_MAINNET_RPC || "https://mainnet.era.zksync.io";
    const batchNum =
      typeof batchNumber === "bigint"
        ? Number(batchNumber)
        : Number(batchNumber);
    const txIndex = Number(txNumberInBatchBigInt);

    logger.info(
      `Looking up L2 transaction hash for batch ${batchNum}, index ${txIndex} (from ${entities.length} initiated withdrawals)`
    );

    l2TransactionHash = await getL2TransactionHashByBatchAndIndex(
      batchNum,
      txIndex,
      rpcUrl,
      3 // 3 retries
    );
  } catch (error) {
    logger.warn(
      `Failed to get L2 transaction hash for batch ${batchNumber.toString()}, index ${txNumberInBatch.toString()}: ${error}`
    );
  }

  // Use l2TransactionHash as ID (same as L2 handler uses)
  // If l2TransactionHash is not available, we can't find the entity
  if (!l2TransactionHash) {
    logger.error(
      `Failed to get L2 transaction hash for batch ${batchNumber.toString()}, index ${txNumberInBatch.toString()}. Cannot find withdrawal.`
    );
    throw new Error(
      `Failed to get L2 transaction hash for batch ${batchNumber.toString()}, index ${txNumberInBatch.toString()}`
    );
  }

  const withdrawalId = l2TransactionHash;

  // Check if withdrawal already exists
  let withdrawal = await BridgeWithdrawal.get(withdrawalId);

  if (!withdrawal) {
    logger.error(`Withdrawal ${withdrawalId} not found`);
    throw new Error(`Withdrawal ${withdrawalId} not found`);
  }

  // Update existing withdrawal with L1 finalization data
  withdrawal.receiverId = receiverAccount.id;
  withdrawal.status = "finalized";

  // Update batch details and finalization info
  withdrawal.batchNumber = batchNumber.toBigInt();
  withdrawal.messageIndex = messageIndex.toBigInt();
  withdrawal.txNumberInBatch = txNumberInBatchBigInt;
  withdrawal.finalizedAt = timestamp;
  withdrawal.l1TransactionHash = event.transaction.hash;

  return withdrawal.save();
}

export async function handleClaimedFailedDeposit(
  event: ClaimedFailedDepositLog
): Promise<void> {
  if (!event.args) {
    logger.error("No event.args in handleClaimedFailedDeposit");
    return;
  }

  const timestamp = BigInt(event.block.timestamp) * BigInt(1000);
  const { to, amount } = event.args;

  const receiverAccount = await fetchAccount(to.toLowerCase(), timestamp);

  // ID is the transaction hash (unique identifier)
  const claimId = event.transaction.hash;

  // Check if claim already exists
  let failedDepositClaim = await BridgeFailedDepositClaim.get(claimId);

  if (!failedDepositClaim) {
    failedDepositClaim = new BridgeFailedDepositClaim(
      claimId,
      timestamp,
      receiverAccount.id,
      amount.toBigInt()
    );
  } else {
    // Update existing claim with latest data
    failedDepositClaim.receiverId = receiverAccount.id;
    failedDepositClaim.amount = amount.toBigInt();
    failedDepositClaim.timestamp = timestamp;
  }

  return failedDepositClaim.save();
}
