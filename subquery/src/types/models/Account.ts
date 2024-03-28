// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type AccountProps = Omit<Account, NonNullable<FunctionPropertyNames<Account>>| '_name'>;

export class Account implements Entity {

    constructor(
        
        id: string,
    ) {
        this.id = id;
        
    }

    public id: string;
    public asERC721Id?: string;
    public asAccessControlId?: string;
    

    get _name(): string {
        return 'Account';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save Account entity without an ID");
        await store.set('Account', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove Account entity without an ID");
        await store.remove('Account', id.toString());
    }

    static async get(id:string): Promise<Account | undefined>{
        assert((id !== null && id !== undefined), "Cannot get Account entity without an ID");
        const record = await store.get('Account', id.toString());
        if (record) {
            return this.create(record as AccountProps);
        } else {
            return;
        }
    }

    static async getByAsERC721Id(asERC721Id: string): Promise<Account[] | undefined>{
      const records = await store.getByField('Account', 'asERC721Id', asERC721Id);
      return records.map(record => this.create(record as AccountProps));
    }

    static async getByAsAccessControlId(asAccessControlId: string): Promise<Account[] | undefined>{
      const records = await store.getByField('Account', 'asAccessControlId', asAccessControlId);
      return records.map(record => this.create(record as AccountProps));
    }

    static async getByFields(filter: FieldsExpression<AccountProps>[], options?: { offset?: number, limit?: number}): Promise<Account[]> {
        const records = await store.getByFields('Account', filter, options);
        return records.map(record => this.create(record as AccountProps));
    }

    static create(record: AccountProps): Account {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
        );
        Object.assign(entity,record);
        return entity;
    }
}
