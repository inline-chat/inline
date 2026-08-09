import { cpSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

type Summary = {
  requestedPackageVersion: string;
  cipherVersion: string;
  sqliteVersion: string;
  durationMilliseconds: number;
  integrity: Record<string, boolean | number>;
  ordering: Record<string, boolean | number>;
  rekey: Record<string, boolean | string>;
};

const repoRoot = dirname(import.meta.dir);
const templateRoot = join(
  repoRoot,
  ".context/overnight-lab/experiments/sqlcipher-stress-package",
);
const timestamp = new Date().toISOString().replaceAll(":", "-").replace(".", "-");
const runRoot = join(repoRoot, ".tmp/overnight-sqlcipher", `ab-${timestamp}`);
const versions = ["4.14.0", "4.17.0"] as const;

mkdirSync(runRoot, { recursive: true });

const summaries: Summary[] = [];
for (const version of versions) {
  const versionRoot = join(runRoot, version);
  const packageRoot = join(versionRoot, "package");
  const artifactRoot = join(versionRoot, "artifacts");
  const scratchRoot = join(versionRoot, "scratch");
  mkdirSync(versionRoot, { recursive: true });
  cpSync(templateRoot, packageRoot, { recursive: true });

  const command = [
    "swift",
    "run",
    "--package-path",
    packageRoot,
    "--scratch-path",
    scratchRoot,
    "-c",
    "release",
    "SQLCipherMediaStress",
    "--output-root",
    artifactRoot,
  ];
  const child = Bun.spawnSync(command, {
    cwd: repoRoot,
    env: { ...Bun.env, INLINE_SQLCIPHER_AB_VERSION: version },
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = child.stdout.toString();
  const stderr = child.stderr.toString();
  writeFileSync(join(versionRoot, "swift-run.stdout.log"), stdout);
  writeFileSync(join(versionRoot, "swift-run.stderr.log"), stderr);

  if (child.exitCode !== 0) {
    writeFileSync(
      join(runRoot, "comparison.json"),
      JSON.stringify({ status: "incomplete", failedVersion: version }, null, 2),
    );
    console.error(`SQLCipher ${version} probe failed; artifacts: ${versionRoot}`);
    process.exit(child.exitCode ?? 1);
  }

  summaries.push(
    JSON.parse(readFileSync(join(artifactRoot, "summary.json"), "utf8")) as Summary,
  );
}

const comparison = {
  status: "complete",
  runRoot,
  versions: summaries,
  sameObservedOutcome: {
    integrity: JSON.stringify(summaries[0]?.integrity) === JSON.stringify(summaries[1]?.integrity),
    ordering: JSON.stringify(summaries[0]?.ordering) === JSON.stringify(summaries[1]?.ordering),
    rekey: JSON.stringify(summaries[0]?.rekey) === JSON.stringify(summaries[1]?.rekey),
  },
};
writeFileSync(join(runRoot, "comparison.json"), JSON.stringify(comparison, null, 2));

console.log(runRoot);
