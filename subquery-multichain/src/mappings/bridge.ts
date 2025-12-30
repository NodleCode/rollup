import { fetchAccount, fetchTransaction } from "../utils/utils";
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

  const l1SenderAccount = await fetchAccount(l1Sender.toLowerCase(), timestamp);
  const l2ReceiverAccount = await fetchAccount(
    l2Receiver.toLowerCase(),
    timestamp
  );
  const emitter = await fetchAccount(event.address.toLowerCase(), timestamp);

  const transaction = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  // Use l2DepositTxHash as common ID between L1 and L2
  // In L2, event.transaction.hash IS the l2DepositTxHash that was emitted in L1
  const network = "zksync"; // L2 network
  const depositId = `deposit-${event.transaction.hash}`;

  // Try to find existing deposit from L1, or create new one
  let deposit = await BridgeDeposit.get(depositId);

  if (!deposit) {
    // Create new deposit if not found from L1
    deposit = new BridgeDeposit(
      depositId,
      emitter.id,
      transaction.id,
      timestamp,
      l1SenderAccount.id,
      l2ReceiverAccount.id,
      amount.toBigInt(),
      network
    );
  } else {
    // Update existing deposit from L1 with L2 data
    // L2 data takes precedence for receiver and amount
    deposit.l2ReceiverId = l2ReceiverAccount.id;
    deposit.amount = amount.toBigInt();
    deposit.timestamp = timestamp;
    deposit.transactionId = transaction.id;
  }

  deposit.hash = event.transaction.hash;
  deposit.l2DepositTxHash = event.transaction.hash;

  await Promise.all([
    deposit.save(),
    l1SenderAccount.save(),
    l2ReceiverAccount.save(),
  ]);
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

  const l2SenderAccount = await fetchAccount(l2Sender.toLowerCase(), timestamp);
  const l1ReceiverAccount = await fetchAccount(
    l1Receiver.toLowerCase(),
    timestamp
  );
  const emitter = await fetchAccount(event.address.toLowerCase(), timestamp);

  const transaction = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  const network = "zksync"; // L2 network

  // ID is the L2 transaction hash (unique identifier from L2)
  const withdrawalId = event.transaction.hash;
  const l2TransactionHash = event.transaction.hash;

  // Check if withdrawal already exists
  let withdrawal = await BridgeWithdrawal.get(withdrawalId);

  if (!withdrawal) {
    withdrawal = new BridgeWithdrawal(
      withdrawalId,
      emitter.id,
      transaction.id,
      timestamp,
      l2SenderAccount.id,
      l1ReceiverAccount.id,
      amount.toBigInt(),
      l2TransactionHash,
      network,
      "initiated", // status
      BigInt(event.block.number) // l2BlockNumber
    );
    withdrawal.hash = event.transaction.hash;
  } else {
    // Update existing withdrawal with latest L2 data
    withdrawal.l2SenderId = l2SenderAccount.id;
    withdrawal.l1ReceiverId = l1ReceiverAccount.id;
    withdrawal.amount = amount.toBigInt();
    withdrawal.timestamp = timestamp;
    withdrawal.transactionId = transaction.id;
    withdrawal.hash = event.transaction.hash;
    withdrawal.l2TransactionHash = l2TransactionHash;
    withdrawal.l2BlockNumber = BigInt(event.block.number);
    // Keep status as is (don't override if already finalized)
    if (withdrawal.status !== "finalized") {
      withdrawal.status = "initiated";
    }
  }

  // batchNumber and messageIndex are not available yet, will be set in L1 handler
  // Leave them as null

  await Promise.all([
    withdrawal.save(),
    l2SenderAccount.save(),
    l1ReceiverAccount.save(),
  ]);
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

  const fromAccount = await fetchAccount(from.toLowerCase(), timestamp);
  const toAccount = await fetchAccount(to.toLowerCase(), timestamp);
  const emitter = await fetchAccount(event.address.toLowerCase(), timestamp);

  const transaction = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  // Use l2DepositTxHash as common ID between L1 and L2
  const network = "ethereum"; // L1 network
  const depositId = `deposit-${l2DepositTxHash}`;

  // Try to find existing deposit from L2, or create new one
  let deposit = await BridgeDeposit.get(depositId);

  if (!deposit) {
    // Create new deposit if not found from L2
    deposit = new BridgeDeposit(
      depositId,
      emitter.id,
      transaction.id,
      timestamp,
      fromAccount.id,
      toAccount.id,
      amount.toBigInt(),
      network
    );
  } else {
    // Update existing deposit from L2 with L1 data
    // L1 data takes precedence for sender and amount
    deposit.l1SenderId = fromAccount.id;
    deposit.amount = amount.toBigInt();
    deposit.timestamp = timestamp;
    deposit.transactionId = transaction.id;
  }

  deposit.hash = event.transaction.hash;
  deposit.l2DepositTxHash = l2DepositTxHash;

  await Promise.all([deposit.save(), fromAccount.save(), toAccount.save()]);
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
  const emitter = await fetchAccount(event.address.toLowerCase(), timestamp);

  const transaction = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  const network = "ethereum"; // L1 network

  // Get L2 transaction hash using zks_getL1BatchBlockRange and eth_getTransactionByBlockNumberAndIndex
  // Use batchNumber and txNumberInBatch (which is the transaction index in the batch) to find the L2 transaction hash
  let l2TransactionHash: string | null = null;

  // Get initiated withdrawals for this receiver
  // Query database directly to avoid SubQuery index validation issues
  const entities = (await store.getByFields(
    "BridgeWithdrawal",
    [
      ["l1_receiver_id" as keyof BridgeWithdrawal, "=", receiverAccount.id],
      ["status", "=", "initiated"],
    ],
    {
      limit: 100,
    }
  )) as BridgeWithdrawal[];

  const blockNumbersToCheck = entities.map((entity) => ({
    blockNumber: Number(entity.l2BlockNumber),
    txHash: entity.l2TransactionHash,
  }));

  logger.info(
    `Will check ${blockNumbersToCheck.length} possible blocks first: ${
      blockNumbersToCheck.length > 0
        ? blockNumbersToCheck
            .map((block) => `${block.blockNumber}:${block.txHash}`)
            .join(", ")
        : "none"
    }`
  );

  try {
    const rpcUrl =
      process.env.ZKSYNC_MAINNET_RPC || "https://mainnet.era.zksync.io";
    const batchNum =
      typeof batchNumber === "bigint"
        ? Number(batchNumber)
        : Number(batchNumber);
    const txIndex = Number(txNumberInBatchBigInt);

    l2TransactionHash = await getL2TransactionHashByBatchAndIndex(
      batchNum,
      txIndex,
      rpcUrl,
      3, // 3 retries
      blockNumbersToCheck || []
    );
  } catch (error) {
    logger.warn(
      `Failed to get L2 transaction hash for batch ${batchNumber.toString()}, index ${txNumberInBatch.toString()}: ${error}`
    );
  }

  // Use l2TransactionHash as ID (same as L2 handler uses)
  // If l2TransactionHash is not available, we can't find the entity
  // In that case, create a new one with a temporary ID
  const withdrawalId = l2TransactionHash!;

  // Check if withdrawal already exists
  let withdrawal = await BridgeWithdrawal.get(withdrawalId);

  if (!withdrawal) {
    logger.error(`Withdrawal ${withdrawalId} not found`);
    throw new Error(`Withdrawal ${withdrawalId} not found`);
  } else {
    // Update existing withdrawal with L1 finalization data
    withdrawal.l1ReceiverId = receiverAccount.id;
    withdrawal.amount = amount.toBigInt();
    withdrawal.timestamp = timestamp;
    withdrawal.transactionId = transaction.id;
    withdrawal.hash = event.transaction.hash;
    withdrawal.status = "finalized";
  }

  // Update batch details and finalization info
  withdrawal.batchNumber = batchNumber.toBigInt();
  withdrawal.messageIndex = messageIndex.toBigInt();
  withdrawal.txNumberInBatch = txNumberInBatchBigInt;
  withdrawal.finalizedAt = timestamp;
  withdrawal.finalizedTransactionId = transaction.id;
  withdrawal.network = network;

  if (l2TransactionHash) {
    withdrawal.l2TransactionHash = l2TransactionHash;
  }

  await Promise.all([withdrawal.save(), receiverAccount.save()]);
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
  const emitter = await fetchAccount(event.address.toLowerCase(), timestamp);

  const transaction = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  const network = "ethereum"; // L1 network

  // ID is the transaction hash (unique identifier)
  const claimId = event.transaction.hash;

  // Check if claim already exists
  let failedDepositClaim = await BridgeFailedDepositClaim.get(claimId);

  if (!failedDepositClaim) {
    failedDepositClaim = new BridgeFailedDepositClaim(
      claimId,
      emitter.id,
      transaction.id,
      timestamp,
      receiverAccount.id,
      amount.toBigInt(),
      network
    );
  } else {
    // Update existing claim with latest data
    failedDepositClaim.receiverId = receiverAccount.id;
    failedDepositClaim.amount = amount.toBigInt();
    failedDepositClaim.timestamp = timestamp;
    failedDepositClaim.transactionId = transaction.id;
  }

  await Promise.all([
    failedDepositClaim.save(),
    receiverAccount.save(),
    transaction.save(),
  ]);
}
