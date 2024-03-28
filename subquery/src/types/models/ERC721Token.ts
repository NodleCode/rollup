// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type ERC721TokenProps = Omit<ERC721Token, NonNullable<FunctionPropertyNames<ERC721Token>>| '_name'>;

export class ERC721Token implements Entity {

    constructor(
        
        id: string,
        contractId: string,
        identifier: bigint,
        ownerId: string,
        approvalId: string,
    ) {
        this.id = id;
        this.contractId = contractId;
        this.identifier = identifier;
        this.ownerId = ownerId;
        this.approvalId = approvalId;
        
    }

    public id: string;
    public contractId: string;
    public identifier: bigint;
    public ownerId: string;
    public approvalId: string;
    public uri?: string;
    public timestamp?: bigint;
    public content?: string;
    public name?: string;
    public transactionHash?: string;
    public description?: string;
    

    get _name(): string {
        return 'ERC721Token';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save ERC721Token entity without an ID");
        await store.set('ERC721Token', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove ERC721Token entity without an ID");
        await store.remove('ERC721Token', id.toString());
    }

    static async get(id:string): Promise<ERC721Token | undefined>{
        assert((id !== null && id !== undefined), "Cannot get ERC721Token entity without an ID");
        const record = await store.get('ERC721Token', id.toString());
        if (record) {
            return this.create(record as ERC721TokenProps);
        } else {
            return;
        }
    }

    static async getByContractId(contractId: string): Promise<ERC721Token[] | undefined>{
      const records = await store.getByField('ERC721Token', 'contractId', contractId);
      return records.map(record => this.create(record as ERC721TokenProps));
    }

    static async getByOwnerId(ownerId: string): Promise<ERC721Token[] | undefined>{
      const records = await store.getByField('ERC721Token', 'ownerId', ownerId);
      return records.map(record => this.create(record as ERC721TokenProps));
    }

    static async getByApprovalId(approvalId: string): Promise<ERC721Token[] | undefined>{
      const records = await store.getByField('ERC721Token', 'approvalId', approvalId);
      return records.map(record => this.create(record as ERC721TokenProps));
    }

    static async getByFields(filter: FieldsExpression<ERC721TokenProps>[], options?: { offset?: number, limit?: number}): Promise<ERC721Token[]> {
        const records = await store.getByFields('ERC721Token', filter, options);
        return records.map(record => this.create(record as ERC721TokenProps));
    }

    static create(record: ERC721TokenProps): ERC721Token {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.contractId,
            record.identifier,
            record.ownerId,
            record.approvalId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
