import { fetchAccount } from "../erc721/erc721";
import { RoleAdminChangedLog, RoleGrantedLog, RoleRevokedLog } from "../types/abi-interfaces/IAccessControl";

export function handleRoleAdminChanged(event: RoleAdminChangedLog): Promise<void> {
  logger.info("handleRoleAdminChanged:", event);

  return Promise.resolve();
}

export function handleRoleGranted(event: RoleGrantedLog): Promise<void> {
  logger.info("handleRoleGranted:", event);
  // const account = fetchAccount();

  return Promise.resolve();
}

export function handleRoleRevoked(event: RoleRevokedLog): Promise<void> {
  logger.info("handleRoleRevoked:", event);
  return Promise.resolve();
}
