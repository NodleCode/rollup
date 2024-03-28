// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type RoleRevokedProps = Omit<RoleRevoked, NonNullable<FunctionPropertyNames<RoleRevoked>>| '_name'>;

export class RoleRevoked implements Entity {

    constructor(
        
        id: string,
        emitterId: string,
        transactionId: string,
        timestamp: bigint,
        roleId: string,
        accountId: string,
        senderId: string,
    ) {
        this.id = id;
        this.emitterId = emitterId;
        this.transactionId = transactionId;
        this.timestamp = timestamp;
        this.roleId = roleId;
        this.accountId = accountId;
        this.senderId = senderId;
        
    }

    public id: string;
    public emitterId: string;
    public transactionId: string;
    public timestamp: bigint;
    public roleId: string;
    public accountId: string;
    public senderId: string;
    

    get _name(): string {
        return 'RoleRevoked';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save RoleRevoked entity without an ID");
        await store.set('RoleRevoked', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove RoleRevoked entity without an ID");
        await store.remove('RoleRevoked', id.toString());
    }

    static async get(id:string): Promise<RoleRevoked | undefined>{
        assert((id !== null && id !== undefined), "Cannot get RoleRevoked entity without an ID");
        const record = await store.get('RoleRevoked', id.toString());
        if (record) {
            return this.create(record as RoleRevokedProps);
        } else {
            return;
        }
    }

    static async getByEmitterId(emitterId: string): Promise<RoleRevoked[] | undefined>{
      const records = await store.getByField('RoleRevoked', 'emitterId', emitterId);
      return records.map(record => this.create(record as RoleRevokedProps));
    }

    static async getByTransactionId(transactionId: string): Promise<RoleRevoked[] | undefined>{
      const records = await store.getByField('RoleRevoked', 'transactionId', transactionId);
      return records.map(record => this.create(record as RoleRevokedProps));
    }

    static async getByRoleId(roleId: string): Promise<RoleRevoked[] | undefined>{
      const records = await store.getByField('RoleRevoked', 'roleId', roleId);
      return records.map(record => this.create(record as RoleRevokedProps));
    }

    static async getByAccountId(accountId: string): Promise<RoleRevoked[] | undefined>{
      const records = await store.getByField('RoleRevoked', 'accountId', accountId);
      return records.map(record => this.create(record as RoleRevokedProps));
    }

    static async getBySenderId(senderId: string): Promise<RoleRevoked[] | undefined>{
      const records = await store.getByField('RoleRevoked', 'senderId', senderId);
      return records.map(record => this.create(record as RoleRevokedProps));
    }

    static async getByFields(filter: FieldsExpression<RoleRevokedProps>[], options?: { offset?: number, limit?: number}): Promise<RoleRevoked[]> {
        const records = await store.getByFields('RoleRevoked', filter, options);
        return records.map(record => this.create(record as RoleRevokedProps));
    }

    static create(record: RoleRevokedProps): RoleRevoked {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.emitterId,
            record.transactionId,
            record.timestamp,
            record.roleId,
            record.accountId,
            record.senderId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
