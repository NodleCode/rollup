// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type TransactionProps = Omit<Transaction, NonNullable<FunctionPropertyNames<Transaction>>| '_name'>;

export class Transaction implements Entity {

    constructor(
        
        id: string,
        timestamp: bigint,
        blockNumber: bigint,
    ) {
        this.id = id;
        this.timestamp = timestamp;
        this.blockNumber = blockNumber;
        
    }

    public id: string;
    public timestamp: bigint;
    public blockNumber: bigint;
    

    get _name(): string {
        return 'Transaction';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save Transaction entity without an ID");
        await store.set('Transaction', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove Transaction entity without an ID");
        await store.remove('Transaction', id.toString());
    }

    static async get(id:string): Promise<Transaction | undefined>{
        assert((id !== null && id !== undefined), "Cannot get Transaction entity without an ID");
        const record = await store.get('Transaction', id.toString());
        if (record) {
            return this.create(record as TransactionProps);
        } else {
            return;
        }
    }

    static async getByFields(filter: FieldsExpression<TransactionProps>[], options?: { offset?: number, limit?: number}): Promise<Transaction[]> {
        const records = await store.getByFields('Transaction', filter, options);
        return records.map(record => this.create(record as TransactionProps));
    }

    static create(record: TransactionProps): Transaction {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.timestamp,
            record.blockNumber,
        );
        Object.assign(entity,record);
        return entity;
    }
}
