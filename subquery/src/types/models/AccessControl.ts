// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type AccessControlProps = Omit<AccessControl, NonNullable<FunctionPropertyNames<AccessControl>>| '_name'>;

export class AccessControl implements Entity {

    constructor(
        
        id: string,
        asAccountId: string,
    ) {
        this.id = id;
        this.asAccountId = asAccountId;
        
    }

    public id: string;
    public asAccountId: string;
    

    get _name(): string {
        return 'AccessControl';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save AccessControl entity without an ID");
        await store.set('AccessControl', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove AccessControl entity without an ID");
        await store.remove('AccessControl', id.toString());
    }

    static async get(id:string): Promise<AccessControl | undefined>{
        assert((id !== null && id !== undefined), "Cannot get AccessControl entity without an ID");
        const record = await store.get('AccessControl', id.toString());
        if (record) {
            return this.create(record as AccessControlProps);
        } else {
            return;
        }
    }

    static async getByAsAccountId(asAccountId: string): Promise<AccessControl[] | undefined>{
      const records = await store.getByField('AccessControl', 'asAccountId', asAccountId);
      return records.map(record => this.create(record as AccessControlProps));
    }

    static async getByFields(filter: FieldsExpression<AccessControlProps>[], options?: { offset?: number, limit?: number}): Promise<AccessControl[]> {
        const records = await store.getByFields('AccessControl', filter, options);
        return records.map(record => this.create(record as AccessControlProps));
    }

    static create(record: AccessControlProps): AccessControl {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.asAccountId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
