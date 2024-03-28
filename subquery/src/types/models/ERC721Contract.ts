// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type ERC721ContractProps = Omit<ERC721Contract, NonNullable<FunctionPropertyNames<ERC721Contract>>| '_name'>;

export class ERC721Contract implements Entity {

    constructor(
        
        id: string,
        asAccountId: string,
    ) {
        this.id = id;
        this.asAccountId = asAccountId;
        
    }

    public id: string;
    public asAccountId: string;
    public supportsMetadata?: boolean;
    public name?: string;
    public symbol?: string;
    

    get _name(): string {
        return 'ERC721Contract';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save ERC721Contract entity without an ID");
        await store.set('ERC721Contract', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove ERC721Contract entity without an ID");
        await store.remove('ERC721Contract', id.toString());
    }

    static async get(id:string): Promise<ERC721Contract | undefined>{
        assert((id !== null && id !== undefined), "Cannot get ERC721Contract entity without an ID");
        const record = await store.get('ERC721Contract', id.toString());
        if (record) {
            return this.create(record as ERC721ContractProps);
        } else {
            return;
        }
    }

    static async getByAsAccountId(asAccountId: string): Promise<ERC721Contract[] | undefined>{
      const records = await store.getByField('ERC721Contract', 'asAccountId', asAccountId);
      return records.map(record => this.create(record as ERC721ContractProps));
    }

    static async getByFields(filter: FieldsExpression<ERC721ContractProps>[], options?: { offset?: number, limit?: number}): Promise<ERC721Contract[]> {
        const records = await store.getByFields('ERC721Contract', filter, options);
        return records.map(record => this.create(record as ERC721ContractProps));
    }

    static create(record: ERC721ContractProps): ERC721Contract {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.asAccountId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
