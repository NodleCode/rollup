// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type RoleAdminChangedProps = Omit<RoleAdminChanged, NonNullable<FunctionPropertyNames<RoleAdminChanged>>| '_name'>;

export class RoleAdminChanged implements Entity {

    constructor(
        
        id: string,
        emitterId: string,
        transactionId: string,
        timestamp: bigint,
        roleId: string,
        newAdminRoleId: string,
        previousAdminRoleId: string,
    ) {
        this.id = id;
        this.emitterId = emitterId;
        this.transactionId = transactionId;
        this.timestamp = timestamp;
        this.roleId = roleId;
        this.newAdminRoleId = newAdminRoleId;
        this.previousAdminRoleId = previousAdminRoleId;
        
    }

    public id: string;
    public emitterId: string;
    public transactionId: string;
    public timestamp: bigint;
    public roleId: string;
    public newAdminRoleId: string;
    public previousAdminRoleId: string;
    

    get _name(): string {
        return 'RoleAdminChanged';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save RoleAdminChanged entity without an ID");
        await store.set('RoleAdminChanged', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove RoleAdminChanged entity without an ID");
        await store.remove('RoleAdminChanged', id.toString());
    }

    static async get(id:string): Promise<RoleAdminChanged | undefined>{
        assert((id !== null && id !== undefined), "Cannot get RoleAdminChanged entity without an ID");
        const record = await store.get('RoleAdminChanged', id.toString());
        if (record) {
            return this.create(record as RoleAdminChangedProps);
        } else {
            return;
        }
    }

    static async getByEmitterId(emitterId: string): Promise<RoleAdminChanged[] | undefined>{
      const records = await store.getByField('RoleAdminChanged', 'emitterId', emitterId);
      return records.map(record => this.create(record as RoleAdminChangedProps));
    }

    static async getByTransactionId(transactionId: string): Promise<RoleAdminChanged[] | undefined>{
      const records = await store.getByField('RoleAdminChanged', 'transactionId', transactionId);
      return records.map(record => this.create(record as RoleAdminChangedProps));
    }

    static async getByRoleId(roleId: string): Promise<RoleAdminChanged[] | undefined>{
      const records = await store.getByField('RoleAdminChanged', 'roleId', roleId);
      return records.map(record => this.create(record as RoleAdminChangedProps));
    }

    static async getByNewAdminRoleId(newAdminRoleId: string): Promise<RoleAdminChanged[] | undefined>{
      const records = await store.getByField('RoleAdminChanged', 'newAdminRoleId', newAdminRoleId);
      return records.map(record => this.create(record as RoleAdminChangedProps));
    }

    static async getByPreviousAdminRoleId(previousAdminRoleId: string): Promise<RoleAdminChanged[] | undefined>{
      const records = await store.getByField('RoleAdminChanged', 'previousAdminRoleId', previousAdminRoleId);
      return records.map(record => this.create(record as RoleAdminChangedProps));
    }

    static async getByFields(filter: FieldsExpression<RoleAdminChangedProps>[], options?: { offset?: number, limit?: number}): Promise<RoleAdminChanged[]> {
        const records = await store.getByFields('RoleAdminChanged', filter, options);
        return records.map(record => this.create(record as RoleAdminChangedProps));
    }

    static create(record: RoleAdminChangedProps): RoleAdminChanged {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.emitterId,
            record.transactionId,
            record.timestamp,
            record.roleId,
            record.newAdminRoleId,
            record.previousAdminRoleId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
