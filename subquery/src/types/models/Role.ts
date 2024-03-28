// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type RoleProps = Omit<Role, NonNullable<FunctionPropertyNames<Role>>| '_name'>;

export class Role implements Entity {

    constructor(
        
        id: string,
    ) {
        this.id = id;
        
    }

    public id: string;
    

    get _name(): string {
        return 'Role';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save Role entity without an ID");
        await store.set('Role', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove Role entity without an ID");
        await store.remove('Role', id.toString());
    }

    static async get(id:string): Promise<Role | undefined>{
        assert((id !== null && id !== undefined), "Cannot get Role entity without an ID");
        const record = await store.get('Role', id.toString());
        if (record) {
            return this.create(record as RoleProps);
        } else {
            return;
        }
    }

    static async getByFields(filter: FieldsExpression<RoleProps>[], options?: { offset?: number, limit?: number}): Promise<Role[]> {
        const records = await store.getByFields('Role', filter, options);
        return records.map(record => this.create(record as RoleProps));
    }

    static create(record: RoleProps): Role {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
        );
        Object.assign(entity,record);
        return entity;
    }
}
