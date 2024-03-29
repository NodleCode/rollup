import assert from "assert";
import {
  RoleAdminChangedLog,
  RoleGrantedLog,
  RoleRevokedLog,
} from "../types/abi-interfaces/Accesscontrol";
import { fetchAccount, fetchTransaction } from "../utils/utils";
import {
  fetchAccessControl,
  fetchAccessControlRole,
  fetchRole,
} from "../utils/accesscontrol";
import {
  AccessControlRoleMember,
  RoleAdminChanged,
  RoleGranted,
  RoleRevoked,
} from "../types";

export async function handleRoleAdminChanged(
  event: RoleAdminChangedLog
): Promise<void> {
  assert(event.args, "No event.args");

  let contract = await fetchAccessControl(event.address);
  let accesscontrolrole = await fetchAccessControlRole(
    contract,
    await fetchRole(event.args.role)
  );
  let admin = await fetchAccessControlRole(
    contract,
    await fetchRole(event.args.newAdminRole)
  );
  let previous = await fetchAccessControlRole(
    contract,
    await fetchRole(event.args.previousAdminRole)
  );

  accesscontrolrole.adminId = admin.id;
  accesscontrolrole.save();

  const evId = event.block.number
    .toString()
    .concat("-")
    .concat(event.logIndex.toString());

  const tx = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  let ev = new RoleAdminChanged(
    evId,
    contract.id,
    tx.id,
    event.block.timestamp,
    accesscontrolrole.id,
    admin.id,
    previous.id
  );

  return ev.save();
}

export async function handleRoleGranted(event: RoleGrantedLog) {
  assert(event.args, "No event.args");
  let contract = await fetchAccessControl(event.address);
  let accesscontrolrole = await fetchAccessControlRole(
    contract,
    await fetchRole(event.args.role)
  );
  let account = await fetchAccount(event.args.account);
  let sender = await fetchAccount(event.args.sender);

  let accesscontrolrolemember = new AccessControlRoleMember(
    accesscontrolrole.id.concat("/").concat(account.id),
    accesscontrolrole.id,
    account.id
  );
  accesscontrolrolemember.save();

  const evId = event.block.number
    .toString()
    .concat("-")
    .concat(event.logIndex.toString());

  const tx = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );
  let ev = new RoleGranted(
    evId,
    contract.id,
    tx.id,
    event.block.timestamp,
    accesscontrolrole.id,
    account.id,
    sender.id
  );

  ev.save();
}

export async function handleRoleRevoked(event: RoleRevokedLog) {
  assert(event.args, "No event.args");

  let contract = await fetchAccessControl(event.address);
  let accesscontrolrole = await fetchAccessControlRole(
    contract,
    await fetchRole(event.args.role)
  );
  let account = await fetchAccount(event.args.account);
  let sender = await fetchAccount(event.args.sender);

  store.remove(
    "AccessControlRoleMember",
    accesscontrolrole.id.concat("/").concat(account.id)
  );

  const evId = event.block.number
    .toString()
    .concat("-")
    .concat(event.logIndex.toString());

  const tx = await fetchTransaction(
    event.transactionHash,
    event.block.timestamp,
    BigInt(event.block.number)
  );

  let ev = new RoleRevoked(
    evId,
    contract.id,
    tx.id,
    event.block.timestamp,
    accesscontrolrole.id,
    account.id,
    sender.id
  );

  ev.save();
}
