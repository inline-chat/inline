const EPOCH = 1726416420000 // 2024-09-15T19:37:00 time of my announcement tweet

// snowflake
// 63 bits max
// max 41 bits for timestamp, or less?
// 10 bit machine ID
// 12 bit sequence

// Inline ID
// must be sequential within entity types thus sortable
// must not disclose any information about the entity or next one
// server made stuff must be centrally managed by us, and not client-side able
// numeric for ease of read and smaller bits
// no randomness ?

// 4-bit: 1 nibble 0-15
// 8-bit: 1 byte 0-255
// 16-bit: 2 bytes 0-65535
30758400000
// 32-bit: 4 bytes 0-4294967295
// 64-bit: 8 bytes 0-18446744073709551615

// Option 1: Time-based

// Option 2: Random-based
// 64 bits
// serial
// custom range
// random difference
// need a centerilized service to manage the ID (maybe in the DB)

// Option 3: Snowflake

// Option 4: UUID

// Option 5: CUID

// Option 6: NanoID
