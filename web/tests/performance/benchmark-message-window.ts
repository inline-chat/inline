import { IDBFactory, IDBKeyRange } from "fake-indexeddb"
import { runMessageWindowBenchmark } from "../../src/testing/benchmarks/MessageWindowBenchmark"

Object.assign(globalThis, {
  indexedDB: new IDBFactory(),
  IDBKeyRange,
})

const result = await runMessageWindowBenchmark({
  environment: "fake-indexeddb",
})

console.log(JSON.stringify(result, null, 2))
