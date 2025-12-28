import { $ } from "bun";
import { watch } from "fs";

const build = async () => {
  console.log("Building...");
  await Bun.build({
    entrypoints: ["./src/index.ts"],
    outdir: "./build",
    external: ["electron"],
    target: "node",
  });
};

const run = () => {
  console.log("Running...");

  const proc = Bun.spawn(["bun", "electron", "build/index.js"], {
    stdout: "inherit",
  });

  return () => {
    console.log("Killing...");
    proc.kill("SIGINT");
  };
};

let killPrev: () => void;

await build();
killPrev = run();

// Build
watch("./src/", async () => {
  killPrev?.();
  try {
    await build();
    killPrev = run();
  } catch (error) {
    console.error("Failed to build");
    console.error(error);
  }
});
