import { Log } from "@in/server/utils/log"

const EPOCH = 1726416420000

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
// 30758400000
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
export class InlineID {
  public static shared = new InlineID(0)

  private static readonly EPOCH = 1726416420000n // 2024-09-15T19:37:00 time of my announcement tweet
  private static readonly TIMESTAMP_BITS = 41n
  private static readonly NODE_ID_BITS = 6n
  private static readonly SEQUENCE_BITS = 14n

  private static readonly MAX_NODE_ID = (1n << InlineID.NODE_ID_BITS) - 1n
  private static readonly MAX_SEQUENCE = (1n << InlineID.SEQUENCE_BITS) - 1n

  private nodeId: bigint
  private sequence: bigint = 0n
  private lastTimestamp: bigint = -1n

  constructor(nodeId: number) {
    if (nodeId < 0 || nodeId > Number(InlineID.MAX_NODE_ID)) {
      throw new Error(`Node ID must be between 0 and ${InlineID.MAX_NODE_ID}`)
    }
    this.nodeId = BigInt(nodeId)
  }

  /**
   * Generates the next unique ID.
   * @param asBigInt If true, returns the ID as a BigInt; otherwise, as a string.
   * @returns The generated ID.
   */
  public async generate(): Promise<bigint> {
    let timestamp = this.currentTimestamp()

    if (timestamp === this.lastTimestamp) {
      this.sequence = (this.sequence + 1n) & InlineID.MAX_SEQUENCE
      if (this.sequence === 0n) {
        timestamp = await this.waitNextMillis(this.lastTimestamp)
      }
    } else {
      this.sequence = 0n
    }

    if (timestamp < this.lastTimestamp) {
      // TODO: Use logger
      // Sentry.captureMessage("Clock moved backwards. Waiting until we catch up.")
      Log.shared.warn("Clock moved backwards. Waiting until we catch up.")
      timestamp = await this.waitNextMillis(this.lastTimestamp)
    }

    this.lastTimestamp = timestamp

    // ID structure: [41 bits timestamp][6 bits node id][14 bits sequence]
    const id =
      ((timestamp - InlineID.EPOCH) << (InlineID.NODE_ID_BITS + InlineID.SEQUENCE_BITS)) |
      (this.nodeId << InlineID.SEQUENCE_BITS) |
      this.sequence

    return id
  }

  /**
   * Extracts information from a generated ID.
   * @param id The ID to extract information from.
   * @returns An object containing the timestamp, node ID, and sequence.
   */
  public static extractInfo(id: bigint): {
    timestamp: Date
    nodeId: number
    sequence: number
  } {
    const timestamp = Number((id >> (InlineID.NODE_ID_BITS + InlineID.SEQUENCE_BITS)) + InlineID.EPOCH)
    const nodeId = Number((id >> InlineID.SEQUENCE_BITS) & InlineID.MAX_NODE_ID)
    const sequence = Number(id & InlineID.MAX_SEQUENCE)

    return {
      timestamp: new Date(timestamp),
      nodeId,
      sequence,
    }
  }

  /**
   * Validates if the given ID is a valid InlineID.
   * @param id The ID to validate.
   * @returns True if the ID is valid, false otherwise.
   */
  public static isValid(id: bigint): boolean {
    try {
      const info = InlineID.extractInfo(id)
      return (
        info.nodeId >= 0 &&
        info.nodeId <= Number(InlineID.MAX_NODE_ID) &&
        info.sequence >= 0 &&
        info.sequence <= Number(InlineID.MAX_SEQUENCE) &&
        info.timestamp.getTime() > Number(InlineID.EPOCH) &&
        info.timestamp.getTime() <= Date.now()
      )
    } catch {
      return false
    }
  }

  private currentTimestamp(): bigint {
    return BigInt(Date.now())
  }

  private async waitNextMillis(lastTimestamp: bigint): Promise<bigint> {
    return new Promise((resolve) => {
      let timestamp = this.currentTimestamp()

      let interval = setInterval(() => {
        if (timestamp <= lastTimestamp) {
          timestamp = this.currentTimestamp()
          clearInterval(interval)
          resolve(timestamp)
        }
      }, 1)
    })
  }
}
