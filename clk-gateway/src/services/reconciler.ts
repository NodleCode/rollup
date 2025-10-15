import { normalizeHandle } from "../utils/handle"
import { handleGuardService } from "./handleGuard"
import { indexerService } from "./indexer"

export class ReconcilerService {
    private intervalId: NodeJS.Timeout | null = null;
    private isRunning = false;

    /**
     * Start the reconciler service
     */
    start(intervalMs: number = 30000): void {
        if (this.intervalId) {
            console.log('Reconciler already running')
            return
        }

        console.log(`Starting reconciler with ${intervalMs}ms interval`)

        this.intervalId = setInterval(async () => {
            if (this.isRunning) {
                console.log('Reconciler still processing, skipping this run')
                return
            }

            try {
                this.isRunning = true
                await this.reconcilePendingReservations()
            } catch (error) {
                console.error('Error during reconciliation:', error)
            } finally {
                this.isRunning = false
            }
        }, intervalMs)
    }

    /**
     * Stop the reconciler service
     */
    stop(): void {
        if (this.intervalId) {
            clearInterval(this.intervalId)
            this.intervalId = null
            console.log('Reconciler stopped')
        }
    }

    /**
     * Reconcile all pending reservations with the indexer
     */
    async reconcilePendingReservations(): Promise<void> {
        console.log('Starting reconciliation of pending reservations')

        try {
            const pendingReservations = await handleGuardService.getPendingReservations()
            console.log(`Found ${pendingReservations.length} pending reservations`)

            for (const { key, reservation } of pendingReservations) {
                try {
                    await this.reconcileReservation(key, reservation)
                } catch (error) {
                    console.error(`Error reconciling reservation ${key}:`, error)
                    // Continue with other reservations even if one fails
                }
            }
        } catch (error) {
            console.error('Error getting pending reservations:', error)
        }
    }

    /**
     * Reconcile a single reservation
     */
    private async reconcileReservation(key: string, reservation: any): Promise<void> {
        if (!reservation.txHash) {
            console.log(`Reservation ${key} has no txHash, skipping`)
            return
        }

        const handle = normalizeHandle(key.replace('handle:', ''))

        try {
            // Check if the handle is now confirmed in the indexer
            const ownership = await indexerService.isHandleTaken(handle)

            if (ownership) {
                // Handle is confirmed in indexer
                if (ownership.owner.toLowerCase() === reservation.owner.toLowerCase()) {
                    console.log(`Handle ${handle} confirmed for owner ${reservation.owner}, removing reservation`)
                    await handleGuardService.removeReservation(key)
                } else {
                    console.log(`Handle ${handle} taken by different owner, removing reservation`)
                    await handleGuardService.removeReservation(key)
                }
            } else {
                // Handle not yet confirmed, check if we should extend TTL or clean up
                await this.handleUnconfirmedReservation(key, reservation, handle)
            }
        } catch (error) {
            console.error(`Error checking handle ${handle} in indexer:`, error)
            // If we can't check the indexer, we might want to keep the reservation for a bit longer
            // or remove it after a maximum age
            await this.handleIndexerError(key, reservation)
        }
    }

    /**
     * Handle unconfirmed reservations
     */
    private async handleUnconfirmedReservation(key: string, reservation: any, handle: string): Promise<void> {
        const now = Math.floor(Date.now() / 1000)
        const age = now - reservation.createdAt

        // If reservation is older than 1 hour, remove it
        const maxAge = 3600 // 1 hour

        if (age > maxAge) {
            console.log(`Reservation ${handle} is too old (${age}s), removing`)
            await handleGuardService.removeReservation(key)
            return
        }

        // Check if we should verify the transaction status on L2
        try {
            await this.verifyTransactionStatus(reservation.txHash, key, reservation, handle)
        } catch (error) {
            console.error(`Error verifying transaction ${reservation.txHash}:`, error)

            // If transaction verification fails and reservation is old, remove it
            if (age > 1800) { // 30 minutes
                console.log(`Cannot verify old transaction ${reservation.txHash}, removing reservation`)
                await handleGuardService.removeReservation(key)
            }
        }
    }

    /**
     * Verify transaction status on L2
     */
    private async verifyTransactionStatus(txHash: string, key: string, reservation: any, handle: string): Promise<void> {
        // This would require access to L2 provider to check transaction status
        // For now, we'll implement a simple timeout-based cleanup

        const now = Math.floor(Date.now() / 1000)
        const age = now - reservation.createdAt

        // If more than 20 minutes have passed and indexer doesn't show the handle,
        // assume transaction failed or there's a delay
        if (age > 1200) { // 20 minutes
            console.log(`Transaction ${txHash} for handle ${handle} not confirmed after 20 minutes, extending TTL with short cooldown`)

            // Set a short TTL (5 minutes) to allow for cleanup while giving some buffer
            await handleGuardService.updateReservationTtl(key, 300)
        }
    }

    /**
     * Handle indexer errors
     */
    private async handleIndexerError(key: string, reservation: any): Promise<void> {
        const now = Math.floor(Date.now() / 1000)
        const age = now - reservation.createdAt

        // If we can't check indexer and reservation is old, clean it up
        if (age > 1800) { // 30 minutes
            console.log(`Cannot check indexer for old reservation ${key}, removing`)
            await handleGuardService.removeReservation(key)
        } else {
            console.log(`Indexer error for reservation ${key}, keeping for now (age: ${age}s)`)
        }
    }

    /**
     * Get reconciler status
     */
    getStatus(): { running: boolean; processing: boolean } {
        return {
            running: this.intervalId !== null,
            processing: this.isRunning
        }
    }
}

export const reconcilerService = new ReconcilerService()
