import { fetchContract } from "../utils/erc20";
import { ApprovalLog, TransferLog } from "../types/abi-interfaces/NODLAbi";
import { fetchAccount, fetchTransaction } from "../utils/utils";
import { ERC20Approval, ERC20Transfer, ERC20TransferV2, Wallet } from "../types";
import { handleLevel, handleSnapshot, handleStatSnapshot } from "../utils/snapshot";

export async function handleERC20Transfer(event: TransferLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
  // logger.info("handleERC20Transfer");

  const contract = await fetchContract(event.address);
  if (contract) {
    const timestamp = event.block.timestamp * BigInt(1000);
    const from = await fetchAccount(event.args.from, timestamp);
    const to = await fetchAccount(event.args.to, timestamp);
    const emitter = await fetchAccount(event.transaction.from, timestamp);
    const value = event.args.value.toBigInt();

    const hash = event.transaction.hash;

    // Create wallet
    let newWallet = 0;
    const toWallet = await Wallet.get(to.id);
    if (!toWallet) {
      newWallet = 1;
      const wallet = new Wallet(to.id, to.id, timestamp);
      wallet.save();
    }

    const transfer = await fetchTransaction(
      hash,
      timestamp,
      BigInt(event.blockNumber)
    );

    const transferEvent = new ERC20Transfer(
      contract.id
        .concat("/")
        .concat(hash)
        .concat("/")
        .concat(`${event.logIndex}`),
      emitter.id,
      transfer.id,
      timestamp,
      from.id,
      to.id,
      value
    );

    const lightTransfer = new ERC20TransferV2(
      contract.id
        .concat("/")
        .concat(hash)
        .concat("/")
        .concat(`${event.logIndex}`),
      emitter.id,
      transfer.id,
      timestamp,
      from.id,
      to.id,
      value
    );
    
    const BigIntZero = BigInt(0);
    const fromBalance = from.balance || BigIntZero;
    const toBalance = to.balance || BigIntZero;
    
    const fromNewBalance = fromBalance - value;
    const toNewBalance = toBalance + value;

    await handleLevel(fromNewBalance, fromBalance, timestamp);
    await handleLevel(toNewBalance, toBalance, timestamp);
    
    // Secure the new balance of the sender is greater than 0
    from.balance = fromNewBalance < BigIntZero ? BigIntZero : fromNewBalance;
    to.balance = toNewBalance; 

    await Promise.all([
      lightTransfer.save(),
      from.save(),
      to.save(),
      handleSnapshot(event, from, value),
      handleSnapshot(event, to, BigInt(0)),
      handleStatSnapshot(timestamp, value, BigInt(0), newWallet),
    ]);

    transferEvent.hash = hash;
    transferEvent.contractId = contract.id;
    transferEvent.emitterId = emitter.id;
    //logger.info("Saving transferEvent");
    return transferEvent.save();
  }
}

export async function handleERC20Approval(event: ApprovalLog): Promise<void> {
  if (!event.args) {
    logger.error("No event.args");
    return;
  }
  // logger.info("handleERC20Approval");

  const contract = await fetchContract(event.address);
  if (contract) {
    const timestamp = event.block.timestamp * BigInt(1000);
    const owner = await fetchAccount(event.args.owner, timestamp);
    const spender = await fetchAccount(event.args.spender, timestamp);
    const value = event.args.value.toBigInt();

    const hash = event.transaction.hash;
    const emitter = await fetchAccount(event.transaction.from, timestamp);

    const transfer = await fetchTransaction(
      hash,
      timestamp,
      BigInt(event.blockNumber)
    );

    const approval = new ERC20Approval(
      contract.id.concat("/").concat(hash),
      emitter.id,
      transfer.id,
      timestamp,
      owner.id,
      spender.id,
      value
    );

    approval.contractId = contract.id;
    approval.hash = hash;

    return approval.save();
  }
}
