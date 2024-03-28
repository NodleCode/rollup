// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type RoleGrantedProps = Omit<RoleGranted, NonNullable<FunctionPropertyNames<RoleGranted>>| '_name'>;

export class RoleGranted implements Entity {

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
        return 'RoleGranted';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save RoleGranted entity without an ID");
        await store.set('RoleGranted', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove RoleGranted entity without an ID");
        await store.remove('RoleGranted', id.toString());
    }

    static async get(id:string): Promise<RoleGranted | undefined>{
        assert((id !== null && id !== undefined), "Cannot get RoleGranted entity without an ID");
        const record = await store.get('RoleGranted', id.toString());
        if (record) {
            return this.create(record as RoleGrantedProps);
        } else {
            return;
        }
    }

    static async getByEmitterId(emitterId: string): Promise<RoleGranted[] | undefined>{
      const records = await store.getByField('RoleGranted', 'emitterId', emitterId);
      return records.map(record => this.create(record as RoleGrantedProps));
    }

    static async getByTransactionId(transactionId: string): Promise<RoleGranted[] | undefined>{
      const records = await store.getByField('RoleGranted', 'transactionId', transactionId);
      return records.map(record => this.create(record as RoleGrantedProps));
    }

    static async getByRoleId(roleId: string): Promise<RoleGranted[] | undefined>{
      const records = await store.getByField('RoleGranted', 'roleId', roleId);
      return records.map(record => this.create(record as RoleGrantedProps));
    }

    static async getByAccountId(accountId: string): Promise<RoleGranted[] | undefined>{
      const records = await store.getByField('RoleGranted', 'accountId', accountId);
      return records.map(record => this.create(record as RoleGrantedProps));
    }

    static async getBySenderId(senderId: string): Promise<RoleGranted[] | undefined>{
      const records = await store.getByField('RoleGranted', 'senderId', senderId);
      return records.map(record => this.create(record as RoleGrantedProps));
    }

    static async getByFields(filter: FieldsExpression<RoleGrantedProps>[], options?: { offset?: number, limit?: number}): Promise<RoleGranted[]> {
        const records = await store.getByFields('RoleGranted', filter, options);
        return records.map(record => this.create(record as RoleGrantedProps));
    }

    static create(record: RoleGrantedProps): RoleGranted {
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
