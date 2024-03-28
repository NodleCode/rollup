// Auto-generated , DO NOT EDIT
import {Entity, FunctionPropertyNames, FieldsExpression} from "@subql/types-core";
import assert from 'assert';



export type EventProps = Omit<Event, NonNullable<FunctionPropertyNames<Event>>| '_name'>;

export class Event implements Entity {

    constructor(
        
        id: string,
        transactionId: string,
        emitterId: string,
        timestamp: bigint,
    ) {
        this.id = id;
        this.transactionId = transactionId;
        this.emitterId = emitterId;
        this.timestamp = timestamp;
        
    }

    public id: string;
    public transactionId: string;
    public emitterId: string;
    public timestamp: bigint;
    

    get _name(): string {
        return 'Event';
    }

    async save(): Promise<void>{
        let id = this.id;
        assert(id !== null, "Cannot save Event entity without an ID");
        await store.set('Event', id.toString(), this);
    }

    static async remove(id:string): Promise<void>{
        assert(id !== null, "Cannot remove Event entity without an ID");
        await store.remove('Event', id.toString());
    }

    static async get(id:string): Promise<Event | undefined>{
        assert((id !== null && id !== undefined), "Cannot get Event entity without an ID");
        const record = await store.get('Event', id.toString());
        if (record) {
            return this.create(record as EventProps);
        } else {
            return;
        }
    }

    static async getByTransactionId(transactionId: string): Promise<Event[] | undefined>{
      const records = await store.getByField('Event', 'transactionId', transactionId);
      return records.map(record => this.create(record as EventProps));
    }

    static async getByEmitterId(emitterId: string): Promise<Event[] | undefined>{
      const records = await store.getByField('Event', 'emitterId', emitterId);
      return records.map(record => this.create(record as EventProps));
    }

    static async getByFields(filter: FieldsExpression<EventProps>[], options?: { offset?: number, limit?: number}): Promise<Event[]> {
        const records = await store.getByFields('Event', filter, options);
        return records.map(record => this.create(record as EventProps));
    }

    static create(record: EventProps): Event {
        assert(typeof record.id === 'string', "id must be provided");
        let entity = new this(
            record.id,
            record.transactionId,
            record.emitterId,
            record.timestamp,
        );
        Object.assign(entity,record);
        return entity;
    }
}
