import { $ } from "bun";
import { watch } from "fs";

const build = async () => {
  console.log("Building...");
  await Bun.build({
    entrypoints: ["./src/index.ts"],
    outdir: "./dist",
    external: ["electron"],
    target: "node",
  });
};

const run = async () => {
  console.log("Running...");
  await $`bun electron dist/index.js`;
};

const buildAndRun = async () => {
  await build();
  await run();
};

buildAndRun();

// Build
watch("./src/", async () => {
  buildAndRun();
});
