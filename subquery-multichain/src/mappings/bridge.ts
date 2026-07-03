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

  // Use l2TransactionHash as common ID between L1 and L2
  // In L2, event.transaction.hash IS the l2TransactionHash that was emitted in L1
  const depositId = event.transaction.hash;

  // The two chain indexers run independently with no ordering guarantee, so
  // the L1-side DepositInitiated may not be indexed yet — create the deposit
  // from L2 data if missing (handleDepositInitiated fills in the L1 fields).
  let deposit = await BridgeDeposit.get(depositId);

  if (!deposit) {
    const senderAccount = await fetchAccount(l1Sender.toLowerCase(), timestamp);
    const receiverAccount = await fetchAccount(
      l2Receiver.toLowerCase(),
      timestamp
    );
    deposit = new BridgeDeposit(
      depositId,
      timestamp,
      senderAccount.id,
      receiverAccount.id,
      amount.toBigInt(),
      "finalized"
    );
  } else {
    deposit.status = "finalized";
  }

  deposit.l2TransactionHash = event.transaction.hash;
  deposit.finalizedAt = timestamp;

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

  // The L2 handler may have already created (and finalized) this deposit —
  // fill in the L1-side fields without regressing finalization state.
  let deposit = await BridgeDeposit.get(depositId);

  if (!deposit) {
    deposit = new BridgeDeposit(
      depositId,
      timestamp,
      senderAccount.id,
      receiverAccount.id,
      amount.toBigInt(),
      "initiated"
    );
  } else {
    deposit.timestamp = timestamp;
    deposit.senderId = senderAccount.id;
    deposit.receiverId = receiverAccount.id;
    deposit.amount = amount.toBigInt();
  }

  deposit.l1TransactionHash = event.transaction.hash;

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

  try {
    const rpcUrl =
      process.env.ZKSYNC_MAINNET_RPC || "https://mainnet.era.zksync.io";
    const batchNum = Number(batchNumber);
    const txIndex = Number(txNumberInBatchBigInt);

    logger.info(
      `Looking up L2 transaction hash for batch ${batchNum}, index ${txIndex}`
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
  const withdrawal = await BridgeWithdrawal.get(withdrawalId);

  if (!withdrawal) {
    // Withdrawals initiated before the L2 startBlock are never indexed —
    // throwing here would permanently halt the L1 indexer on this block.
    logger.warn(
      `Withdrawal ${withdrawalId} not found, skipping finalization update`
    );
    return;
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

  const failedDepositClaim = new BridgeFailedDepositClaim(
    claimId,
    timestamp,
    receiverAccount.id,
    amount.toBigInt()
  );

  return failedDepositClaim.save();
}
