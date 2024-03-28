import { ApprovalLog, TransferLog } from "../types/abi-interfaces/Erc20Abi";


export function handleTransfer(event: TransferLog): Promise<void>  {
  
}

export function handleApproval(event: ApprovalLog): Promise<void>  {
}

export function handleApprovalForAll(event: any): Promise<void>  {
  let contract = fetchERC721(event.address);
  if (contract != null) {
    let owner = fetchAccount(event.params.owner);
    let operator = fetchAccount(event.params.operator);
    let delegation = fetchERC721Operator(contract, owner, operator);

    delegation.approved = event.params.approved;

    delegation.save();

    // 	let ev = new ApprovalForAll(events.id(event))
    // 	ev.emitter     = contract.id
    // 	ev.transaction = transactions.log(event).id
    // 	ev.timestamp   = event.block.timestamp
    // 	ev.delegation  = delegation.id
    // 	ev.owner       = owner.id
    // 	ev.operator    = operator.id
    // 	ev.approved    = event.params.approved
    // 	ev.save()
  }
}
