import { copyFile } from "node:fs/promises"

await copyFile(new URL("../src/silero_vad.onnx", import.meta.url), new URL("./silero_vad.onnx", import.meta.url))
await copyFile(new URL("../src/silero-model-license.txt", import.meta.url), new URL("./silero-model-license.txt", import.meta.url))
