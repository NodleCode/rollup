import { indexerUrl } from "../setup"

export interface HandleOwnership {
    ensName: string
    owner: string
    handle: string
}

export class IndexerService {
    private baseUrl: string

    constructor(baseUrl: string = indexerUrl) {
        this.baseUrl = baseUrl
    }

    /**
     * Check if a handle is taken by querying all ENS profiles for text records
     */
    async isHandleTaken(handle: string): Promise<HandleOwnership | null> {
        const normalizedHandle = this.normalizeHandle(handle)

        try {
            // Query to fetch all ENS profiles with text records containing the handle
            const query = `
        query FindHandleOwnership($handle: String!) {
          ensProfiles(filter: { textRecords: { some: { key: { equalTo: "com.x" }, value: { equalTo: $handle } } } }) {
            nodes {
              completeName
              owner {
                id
              }
              textRecords {
                nodes {
                  key
                  value
                }
              }
            }
          }
        }
      `

            const response = await fetch(this.baseUrl, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    query,
                    variables: { handle: normalizedHandle }
                }),
            })

            if (!response.ok) {
                throw new Error(`GraphQL query failed: ${response.statusText}`)
            }

            const data = await response.json()

            if (data.errors) {
                console.error('GraphQL errors:', data.errors)
                throw new Error('GraphQL query returned errors')
            }

            const profiles = data.data?.ensProfiles?.nodes || []

            // Find the first profile that has the handle in com.x text record
            for (const profile of profiles) {
                const textRecords = profile.textRecords?.nodes || []
                const xRecord = textRecords.find((record: any) =>
                    record.key === 'com.x' && record.value === normalizedHandle
                )

                if (xRecord) {
                    return {
                        ensName: profile.completeName,
                        owner: profile.owner.id,
                        handle: normalizedHandle
                    }
                }
            }

            return null
        } catch (error) {
            console.error('Error querying indexer for handle:', error)
            throw new Error('Failed to check handle availability')
        }
    }

    /**
     * Check if an ENS name has a specific text record
     */
    async getTextRecord(ensName: string, key: string): Promise<string | null> {
        try {
            const query = `
        query GetTextRecord($ensName: String!, $key: String!) {
          ensProfiles(filter: { completeName: { equalTo: $ensName } }) {
            nodes {
              textRecords(filter: { key: { equalTo: $key } }) {
                nodes {
                  value
                }
              }
            }
          }
        }
      `

            const response = await fetch(this.baseUrl, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    query,
                    variables: { ensName, key }
                }),
            })

            if (!response.ok) {
                throw new Error(`GraphQL query failed: ${response.statusText}`)
            }

            const data = await response.json()

            if (data.errors) {
                console.error('GraphQL errors:', data.errors)
                return null
            }

            const profiles = data.data?.ensProfiles?.nodes || []

            if (profiles.length === 0) {
                return null
            }

            const textRecords = profiles[0].textRecords?.nodes || []
            return textRecords.length > 0 ? textRecords[0].value : null
        } catch (error) {
            console.error('Error querying text record:', error)
            return null
        }
    }

    private normalizeHandle(handle: string): string {
        // Remove leading @, trim, and lowercase
        return handle.replace(/^@/, '').trim().toLowerCase()
    }
}

export const indexerService = new IndexerService()
