import { describe, expect, test } from "bun:test"
import { assertMigrationHead, assertMigrationLedger, sourceMigrations } from "./migrationState"

const source = [
  { createdAt: 100, hash: "one" },
  { createdAt: 200, hash: "two" },
]

describe("migration ledger gate", () => {
  test("uses the packaged journal and SQL hashes", () => {
    const records = sourceMigrations()
    expect(records.length).toBeGreaterThan(100)
    expect(records.at(-1)?.createdAt).toBeGreaterThan(records[0]!.createdAt)
    expect(records.every(({ hash }) => /^[a-f0-9]{64}$/.test(hash))).toBe(true)
  })

  test("prevents startup on a missing, partial, or modified migration history", () => {
    expect(() => assertMigrationLedger(source, [], "startup")).toThrow("behind")
    expect(() => assertMigrationLedger(source, source.slice(0, 1), "startup")).toThrow("behind")
    expect(() => assertMigrationLedger(source, [source[0]!, { ...source[1]!, hash: "changed" }], "startup")).toThrow(
      "differs",
    )
    expect(() => assertMigrationLedger(source, source, "startup")).not.toThrow()
  })

  test("allows a newer database only for startup when its known history matches", () => {
    const ahead = [...source, { createdAt: 300, hash: "three" }]
    expect(() => assertMigrationLedger(source, ahead, "startup")).not.toThrow()
    expect(() => assertMigrationLedger(source, ahead, "preflight")).toThrow("ahead")
    expect(() => assertMigrationLedger(source, ahead, "current")).toThrow("ahead")
    expect(() =>
      assertMigrationLedger(source, [source[0]!, { ...source[1]!, hash: "changed" }, ahead[2]!], "startup"),
    ).toThrow("differs")
  })

  test("migration command accepts only a matching prefix before writing and exact result after", () => {
    expect(() => assertMigrationLedger(source, [], "preflight")).not.toThrow()
    expect(() => assertMigrationLedger(source, [source[0]!], "preflight")).not.toThrow()
    expect(() => assertMigrationLedger(source, [source[0]!], "current")).toThrow("behind")
    expect(() => assertMigrationLedger(source, source, "current")).not.toThrow()
    expect(() => assertMigrationLedger(source, [source[0]!, source[0]!], "current")).toThrow("duplicated")
  })

  test("accepts old branch migrations but never skips a required migration", () => {
    const historical = [source[0]!, { createdAt: 150, hash: "retired" }, source[1]!]
    expect(() => assertMigrationLedger(source, historical, "startup")).not.toThrow()
    expect(() => assertMigrationLedger(source, historical, "current")).not.toThrow()
    expect(() => assertMigrationLedger(source, [source[0]!, { createdAt: 250, hash: "retired" }], "startup")).toThrow(
      "missing",
    )
  })

  test("accepts the public 0150 prefix but rejects the superseded local index branch", () => {
    const public0150 = { createdAt: 1790121600000, hash: "public-space-profiles" }
    const insights0151 = { createdAt: 1790193451066, hash: "insights-indexes" }
    const reconciled = [source[0]!, public0150, insights0151]

    expect(() => assertMigrationLedger(reconciled, [source[0]!, public0150], "preflight")).not.toThrow()
    expect(() =>
      assertMigrationLedger(
        reconciled,
        [
          source[0]!,
          {
            createdAt: 1790118615970,
            hash: "a160f2c1cf8f2abee0ad4e0e8b5988ad388904ab92abfc5614d0bf69b5f99ccc",
          },
        ],
        "preflight",
      ),
    ).toThrow("superseded local 0150")
  })

  test("historical SQL hash drift does not reject a database with the required head", () => {
    const applied = [{ ...source[0]!, hash: "older-sql" }, source[1]!]
    expect(() => assertMigrationLedger(source, applied, "startup")).not.toThrow()
    expect(() => assertMigrationLedger(source, applied, "current")).not.toThrow()
  })

  test("readiness rejects a restored or changed migration head", () => {
    expect(() =>
      assertMigrationHead(source[1]!, {
        required_hash: "two",
        latest_created_at: 200,
      }),
    ).not.toThrow()
    expect(() =>
      assertMigrationHead(source[1]!, {
        required_hash: "two",
        latest_created_at: 300,
      }),
    ).not.toThrow()
    expect(() =>
      assertMigrationHead(source[1]!, {
        required_hash: null,
        latest_created_at: 100,
      }),
    ).toThrow("behind")
    expect(() =>
      assertMigrationHead(source[1]!, {
        required_hash: "changed",
        latest_created_at: 300,
      }),
    ).toThrow("differs")
  })
})
