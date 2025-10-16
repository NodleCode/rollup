
import { createClient } from 'redis'

describe('Redis Connection', () => {
    it('should successfully set, get, and delete a key', async () => {
        const client = await createClient({
            url: "redis://localhost:6380",
        })
            .on("error", (err) => console.log("Redis Client Error", err))
            .connect()

        await client.set("key", "value")
        const value = await client.get("key")
        expect(value).toBe("value")

        await client.del("key")
        const deletedValue = await client.get("key")
        expect(deletedValue).toBeNull()
    }, 30000) // 30 second timeout for integration test
})
