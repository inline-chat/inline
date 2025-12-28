import { platform } from "os";
const p = platform();
export const isMacOS = p == "darwin";
