// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type AccessControlRoleMemberProps = Omit<AccessControlRoleMember, NonNullable<FunctionPropertyNames<AccessControlRoleMember>>| '_name'>;

export class AccessControlRoleMember implements Entity {

    constructor(
        
        id: string,
        accesscontrolroleId: string,
        accountId: string,
    ) {
        this.id = id;
        this.accesscontrolroleId = accesscontrolroleId;
        this.accountId = accountId;
        
    }

    public id: string;
    public accesscontrolroleId: string;
    public accountId: string;
    

    get _name(): string {
        return 'AccessControlRoleMember';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save AccessControlRoleMember entity without an ID");
        await store.set('AccessControlRoleMember', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove AccessControlRoleMember entity without an ID");
        await store.remove('AccessControlRoleMember', id.toString());
    }

    static async get(id:string): Promise<AccessControlRoleMember | undefined>{
        assert((id !== null && id !== undefined), "Cannot get AccessControlRoleMember entity without an ID");
        const record = await store.get('AccessControlRoleMember', id.toString());
        if (record) {
            return this.create(record as AccessControlRoleMemberProps);
        } else {
            return;
        }
    }

    static async getByAccesscontrolroleId(accesscontrolroleId: string): Promise<AccessControlRoleMember[] | undefined>{
      const records = await store.getByField('AccessControlRoleMember', 'accesscontrolroleId', accesscontrolroleId);
      return records.map(record => this.create(record as AccessControlRoleMemberProps));
    }

    static async getByAccountId(accountId: string): Promise<AccessControlRoleMember[] | undefined>{
      const records = await store.getByField('AccessControlRoleMember', 'accountId', accountId);
      return records.map(record => this.create(record as AccessControlRoleMemberProps));
    }

    static async getByFields(filter: FieldsExpression<AccessControlRoleMemberProps>[], options?: { offset?: number, limit?: number}): Promise<AccessControlRoleMember[]> {
        const records = await store.getByFields('AccessControlRoleMember', filter, options);
        return records.map(record => this.create(record as AccessControlRoleMemberProps));
    }

    static create(record: AccessControlRoleMemberProps): AccessControlRoleMember {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.accesscontrolroleId,
            record.accountId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
