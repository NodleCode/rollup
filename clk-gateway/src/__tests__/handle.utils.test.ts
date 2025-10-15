import { getHandleKey, isReservedHandle, normalizeHandle, validateHandle } from '../utils/handle'

describe('Handle Utils', () => {
    describe('normalizeHandle', () => {
        it('should remove leading @ symbol', () => {
            expect(normalizeHandle('@testhandle')).toBe('testhandle')
        })

        it('should convert to lowercase', () => {
            expect(normalizeHandle('TestHandle')).toBe('testhandle')
        })

        it('should trim whitespace', () => {
            expect(normalizeHandle('  testhandle  ')).toBe('testhandle')
        })

        it('should handle combination of transformations', () => {
            expect(normalizeHandle('  @TestHandle  ')).toBe('testhandle')
        })
    })

    describe('validateHandle', () => {
        it('should accept valid handles', () => {
            expect(validateHandle('testhandle')).toEqual({ isValid: true })
            expect(validateHandle('test_handle')).toEqual({ isValid: true })
            expect(validateHandle('test123')).toEqual({ isValid: true })
        })

        it('should reject empty handles', () => {
            expect(validateHandle('')).toEqual({
                isValid: false,
                error: 'Handle must be a non-empty string'
            })
            expect(validateHandle('   ')).toEqual({
                isValid: false,
                error: 'Handle cannot be empty after normalization'
            })
        })

        it('should reject too short handles', () => {
            expect(validateHandle('ab')).toEqual({
                isValid: false,
                error: 'Handle must be at least 3 characters long'
            })
        })

        it('should reject too long handles', () => {
            const longHandle = 'a'.repeat(31)
            expect(validateHandle(longHandle)).toEqual({
                isValid: false,
                error: 'Handle must be no more than 30 characters long'
            })
        })

        it('should reject invalid characters', () => {
            expect(validateHandle('test-handle')).toEqual({
                isValid: false,
                error: 'Handle can only contain letters, numbers, and underscores'
            })
            expect(validateHandle('test handle')).toEqual({
                isValid: false,
                error: 'Handle can only contain letters, numbers, and underscores'
            })
            expect(validateHandle('test@handle')).toEqual({
                isValid: false,
                error: 'Handle can only contain letters, numbers, and underscores'
            })
        })

        it('should reject handles starting or ending with underscore', () => {
            expect(validateHandle('_testhandle')).toEqual({
                isValid: false,
                error: 'Handle cannot start or end with underscore'
            })
            expect(validateHandle('testhandle_')).toEqual({
                isValid: false,
                error: 'Handle cannot start or end with underscore'
            })
        })

        it('should reject handles with consecutive underscores', () => {
            expect(validateHandle('test__handle')).toEqual({
                isValid: false,
                error: 'Handle cannot contain consecutive underscores'
            })
        })
    })

    describe('getHandleKey', () => {
        it('should generate correct Redis key', () => {
            expect(getHandleKey('testhandle')).toBe('handle:testhandle')
            expect(getHandleKey('@TestHandle')).toBe('handle:testhandle')
        })
    })

    describe('isReservedHandle', () => {
        it('should identify reserved handles', () => {
            expect(isReservedHandle('admin')).toBe(true)
            expect(isReservedHandle('root')).toBe(true)
            expect(isReservedHandle('api')).toBe(true)
            expect(isReservedHandle('ADMIN')).toBe(true) // Case insensitive
        })

        it('should allow non-reserved handles', () => {
            expect(isReservedHandle('testhandle')).toBe(false)
            expect(isReservedHandle('myuser')).toBe(false)
        })
    })
})
