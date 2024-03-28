// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type AccessControlRoleProps = Omit<AccessControlRole, NonNullable<FunctionPropertyNames<AccessControlRole>>| '_name'>;

export class AccessControlRole implements Entity {

    constructor(
        
        id: string,
        contractId: string,
        roleId: string,
        adminId: string,
    ) {
        this.id = id;
        this.contractId = contractId;
        this.roleId = roleId;
        this.adminId = adminId;
        
    }

    public id: string;
    public contractId: string;
    public roleId: string;
    public adminId: string;
    

    get _name(): string {
        return 'AccessControlRole';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save AccessControlRole entity without an ID");
        await store.set('AccessControlRole', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove AccessControlRole entity without an ID");
        await store.remove('AccessControlRole', id.toString());
    }

    static async get(id:string): Promise<AccessControlRole | undefined>{
        assert((id !== null && id !== undefined), "Cannot get AccessControlRole entity without an ID");
        const record = await store.get('AccessControlRole', id.toString());
        if (record) {
            return this.create(record as AccessControlRoleProps);
        } else {
            return;
        }
    }

    static async getByContractId(contractId: string): Promise<AccessControlRole[] | undefined>{
      const records = await store.getByField('AccessControlRole', 'contractId', contractId);
      return records.map(record => this.create(record as AccessControlRoleProps));
    }

    static async getByRoleId(roleId: string): Promise<AccessControlRole[] | undefined>{
      const records = await store.getByField('AccessControlRole', 'roleId', roleId);
      return records.map(record => this.create(record as AccessControlRoleProps));
    }

    static async getByAdminId(adminId: string): Promise<AccessControlRole[] | undefined>{
      const records = await store.getByField('AccessControlRole', 'adminId', adminId);
      return records.map(record => this.create(record as AccessControlRoleProps));
    }

    static async getByFields(filter: FieldsExpression<AccessControlRoleProps>[], options?: { offset?: number, limit?: number}): Promise<AccessControlRole[]> {
        const records = await store.getByFields('AccessControlRole', filter, options);
        return records.map(record => this.create(record as AccessControlRoleProps));
    }

    static create(record: AccessControlRoleProps): AccessControlRole {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.contractId,
            record.roleId,
            record.adminId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
