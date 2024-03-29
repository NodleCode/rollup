// SPDX-License-Identifier: Apache-2.0

// Auto-generated , DO NOT EDIT
import {EthereumLog, EthereumTransaction, LightEthereumLog} from "@subql/types-ethereum";

import {RoleAdminChangedEvent, RoleGrantedEvent, RoleRevokedEvent, IAccessControl} from '../contracts/IAccessControl'


export type RoleAdminChangedLog = EthereumLog<RoleAdminChangedEvent["args"]>

export type RoleGrantedLog = EthereumLog<RoleGrantedEvent["args"]>

export type RoleRevokedLog = EthereumLog<RoleRevokedEvent["args"]>


export type LightRoleAdminChangedLog = LightEthereumLog<RoleAdminChangedEvent["args"]>

export type LightRoleGrantedLog = LightEthereumLog<RoleGrantedEvent["args"]>

export type LightRoleRevokedLog = LightEthereumLog<RoleRevokedEvent["args"]>


export type GetRoleAdminTransaction = EthereumTransaction<Parameters<IAccessControl['functions']['getRoleAdmin']>>

export type GrantRoleTransaction = EthereumTransaction<Parameters<IAccessControl['functions']['grantRole']>>

export type HasRoleTransaction = EthereumTransaction<Parameters<IAccessControl['functions']['hasRole']>>

export type RenounceRoleTransaction = EthereumTransaction<Parameters<IAccessControl['functions']['renounceRole']>>

export type RevokeRoleTransaction = EthereumTransaction<Parameters<IAccessControl['functions']['revokeRole']>>

