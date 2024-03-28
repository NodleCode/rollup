// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type ERC721TransferProps = Omit<ERC721Transfer, NonNullable<FunctionPropertyNames<ERC721Transfer>>| '_name'>;

export class ERC721Transfer implements Entity {

    constructor(
        
        id: string,
        emitterId: string,
        transactionId: string,
        timestamp: bigint,
        contractId: string,
        tokenId: string,
        fromId: string,
        toId: string,
    ) {
        this.id = id;
        this.emitterId = emitterId;
        this.transactionId = transactionId;
        this.timestamp = timestamp;
        this.contractId = contractId;
        this.tokenId = tokenId;
        this.fromId = fromId;
        this.toId = toId;
        
    }

    public id: string;
    public emitterId: string;
    public transactionId: string;
    public timestamp: bigint;
    public contractId: string;
    public tokenId: string;
    public fromId: string;
    public toId: string;
    

    get _name(): string {
        return 'ERC721Transfer';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save ERC721Transfer entity without an ID");
        await store.set('ERC721Transfer', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove ERC721Transfer entity without an ID");
        await store.remove('ERC721Transfer', id.toString());
    }

    static async get(id:string): Promise<ERC721Transfer | undefined>{
        assert((id !== null && id !== undefined), "Cannot get ERC721Transfer entity without an ID");
        const record = await store.get('ERC721Transfer', id.toString());
        if (record) {
            return this.create(record as ERC721TransferProps);
        } else {
            return;
        }
    }

    static async getByEmitterId(emitterId: string): Promise<ERC721Transfer[] | undefined>{
      const records = await store.getByField('ERC721Transfer', 'emitterId', emitterId);
      return records.map(record => this.create(record as ERC721TransferProps));
    }

    static async getByTransactionId(transactionId: string): Promise<ERC721Transfer[] | undefined>{
      const records = await store.getByField('ERC721Transfer', 'transactionId', transactionId);
      return records.map(record => this.create(record as ERC721TransferProps));
    }

    static async getByContractId(contractId: string): Promise<ERC721Transfer[] | undefined>{
      const records = await store.getByField('ERC721Transfer', 'contractId', contractId);
      return records.map(record => this.create(record as ERC721TransferProps));
    }

    static async getByTokenId(tokenId: string): Promise<ERC721Transfer[] | undefined>{
      const records = await store.getByField('ERC721Transfer', 'tokenId', tokenId);
      return records.map(record => this.create(record as ERC721TransferProps));
    }

    static async getByFromId(fromId: string): Promise<ERC721Transfer[] | undefined>{
      const records = await store.getByField('ERC721Transfer', 'fromId', fromId);
      return records.map(record => this.create(record as ERC721TransferProps));
    }

    static async getByToId(toId: string): Promise<ERC721Transfer[] | undefined>{
      const records = await store.getByField('ERC721Transfer', 'toId', toId);
      return records.map(record => this.create(record as ERC721TransferProps));
    }

    static async getByFields(filter: FieldsExpression<ERC721TransferProps>[], options?: { offset?: number, limit?: number}): Promise<ERC721Transfer[]> {
        const records = await store.getByFields('ERC721Transfer', filter, options);
        return records.map(record => this.create(record as ERC721TransferProps));
    }

    static create(record: ERC721TransferProps): ERC721Transfer {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.emitterId,
            record.transactionId,
            record.timestamp,
            record.contractId,
            record.tokenId,
            record.fromId,
            record.toId,
        );
        Object.assign(entity,record);
        return entity;
    }
}
