import { dirname, resolve } from "path";
import { realpath } from "fs/promises";

const cliDirectory = await realpath(resolve(import.meta.dir, "..", "cli"));
const publicReleaseScript = resolve(dirname(cliDirectory), "scripts", "release-cli.ts");
const processHandle = Bun.spawn(
  ["bun", "run", publicReleaseScript, ...process.argv.slice(2)],
  {
    cwd: import.meta.dir,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  },
);

process.exit(await processHandle.exited);
