import { platform } from "node:os"

const currentPlatform = platform()
export const isMacOS = currentPlatform === "darwin"
