// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type ERC721OperatorProps = Omit<ERC721Operator, NonNullable<FunctionPropertyNames<ERC721Operator>>| '_name'>;

export class ERC721Operator implements Entity {

    constructor(
        
        id: string,
        contractId: string,
        ownerId: string,
        operatorId: string,
        approved: boolean,
    ) {
        this.id = id;
        this.contractId = contractId;
        this.ownerId = ownerId;
        this.operatorId = operatorId;
        this.approved = approved;
        
    }

    public id: string;
    public contractId: string;
    public ownerId: string;
    public operatorId: string;
    public approved: boolean;
    

    get _name(): string {
        return 'ERC721Operator';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save ERC721Operator entity without an ID");
        await store.set('ERC721Operator', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove ERC721Operator entity without an ID");
        await store.remove('ERC721Operator', id.toString());
    }

    static async get(id:string): Promise<ERC721Operator | undefined>{
        assert((id !== null && id !== undefined), "Cannot get ERC721Operator entity without an ID");
        const record = await store.get('ERC721Operator', id.toString());
        if (record) {
            return this.create(record as ERC721OperatorProps);
        } else {
            return;
        }
    }

    static async getByContractId(contractId: string): Promise<ERC721Operator[] | undefined>{
      const records = await store.getByField('ERC721Operator', 'contractId', contractId);
      return records.map(record => this.create(record as ERC721OperatorProps));
    }

    static async getByOwnerId(ownerId: string): Promise<ERC721Operator[] | undefined>{
      const records = await store.getByField('ERC721Operator', 'ownerId', ownerId);
      return records.map(record => this.create(record as ERC721OperatorProps));
    }

    static async getByOperatorId(operatorId: string): Promise<ERC721Operator[] | undefined>{
      const records = await store.getByField('ERC721Operator', 'operatorId', operatorId);
      return records.map(record => this.create(record as ERC721OperatorProps));
    }

    static async getByFields(filter: FieldsExpression<ERC721OperatorProps>[], options?: { offset?: number, limit?: number}): Promise<ERC721Operator[]> {
        const records = await store.getByFields('ERC721Operator', filter, options);
        return records.map(record => this.create(record as ERC721OperatorProps));
    }

    static create(record: ERC721OperatorProps): ERC721Operator {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.contractId,
            record.ownerId,
            record.operatorId,
            record.approved,
        );
        Object.assign(entity,record);
        return entity;
    }
}
