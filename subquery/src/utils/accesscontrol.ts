import { constants } from "@amxx/graphprotocol-utils";
import { AccessControl, AccessControlRole, Role } from "../types";
import { fetchAccount } from "./utils";

export async function fetchRole(id: string): Promise<Role> {
  let role = await Role.get(id);

  if (!role) {
    role = new Role(id);
    role.save();
  }

  return role;
}

export async function fetchAccessControl(address: string): Promise<AccessControl> {
  let contract = await AccessControl.get(address);

  if (!contract) {
    contract = new AccessControl(address, address);
    contract.save();

    let account = await fetchAccount(address);
    account.asAccessControlId = address;
    await account.save();
  }

  return contract;
}

export async function fetchAccessControlRole(
  contract: AccessControl,
  role: Role
): Promise<AccessControlRole> {
  let id = contract.id.concat("/").concat(role.id);
  let acr = await AccessControlRole.get(id);

  if (acr == null) {
    const admin =
      role.id == constants.BYTES32_ZERO.toString()
        ? id
        : (await fetchAccessControlRole(contract, await fetchRole(constants.BYTES32_ZERO.toString())))
            .id;
    acr = new AccessControlRole(id, id, role.id, admin);
    
    acr.save();
  }

  return acr as AccessControlRole;
}
