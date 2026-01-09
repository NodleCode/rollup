import { EthereumLog } from "@subql/types-ethereum";
import { fetchAccount, fetchTransaction } from "../utils/utils";
import { BridgeWithdrawal, BridgeDeposit } from "../types";

// Event types based on IL2Bridge interface
interface DepositFinalizedEventArgs {
  l1Sender: string;
  l2Receiver: string;
  amount: { toBigInt(): bigint };
}

interface WithdrawalInitiatedEventArgs {
  l2Sender: string;
  l1Receiver: string;
  amount: { toBigInt(): bigint };
}

type DepositFinalizedLog = EthereumLog<DepositFinalizedEventArgs>;
type WithdrawalInitiatedLog = EthereumLog<WithdrawalInitiatedEventArgs>;

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
  const l2ReceiverAccount = await fetchAccount(l2Receiver.toLowerCase(), timestamp);
  const emitter = await fetchAccount(event.address.toLowerCase(), timestamp);

  const transaction = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  const depositId = `${event.transaction.hash}-${event.logIndex}`;

  const deposit = new BridgeDeposit(
    depositId,
    emitter.id,
    transaction.id,
    timestamp,
    l1SenderAccount.id,
    l2ReceiverAccount.id,
    amount.toBigInt()
  );

  deposit.hash = event.transaction.hash;

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
  const l1ReceiverAccount = await fetchAccount(l1Receiver.toLowerCase(), timestamp);
  const emitter = await fetchAccount(event.address.toLowerCase(), timestamp);

  const transaction = await fetchTransaction(
    event.transaction.hash,
    timestamp,
    BigInt(event.block.number)
  );

  const withdrawalId = `${event.transaction.hash}-${event.logIndex}`;

  const withdrawal = new BridgeWithdrawal(
    withdrawalId,
    emitter.id,
    transaction.id,
    timestamp,
    l2SenderAccount.id,
    l1ReceiverAccount.id,
    amount.toBigInt()
  );

  withdrawal.hash = event.transaction.hash;
  withdrawal.finalized = false;

  await Promise.all([
    withdrawal.save(),
    l2SenderAccount.save(),
    l1ReceiverAccount.save(),
  ]);
}

