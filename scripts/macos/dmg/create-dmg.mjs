#!/usr/bin/env node
// Builds the Inline DMG with our install background.
//
// create-dmg has no background option, so this replays its build with the
// globally installed package's own appdmg and volume-icon composer. Apart from
// the window background, the result matches `create-dmg --identity=...`.
// Runs under Node, not Bun: appdmg depends on native Node addons.
//
// Usage: node create-dmg.mjs <app> <output.dmg> <codesign identity>

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const [appPath, dmgPath, identity] = process.argv.slice(2);
if (!appPath || !dmgPath || !identity) {
  console.error("usage: create-dmg.mjs <app> <output.dmg> <codesign identity>");
  process.exit(1);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const background = path.join(here, "background.png"); // appdmg picks up background@2x.png beside it

const createDmgDir =
  process.env.CREATE_DMG_DIR ||
  path.join(execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim(), "create-dmg");
const createDmgRequire = createRequire(path.join(createDmgDir, "package.json"));
const appdmg = createDmgRequire("appdmg");
const { default: composeIcon } = await import(pathToFileURL(path.join(createDmgDir, "compose-icon.js")).href);

const infoPlistPath = path.join(appPath, "Contents/Info.plist");
const plistValue = (key) => {
  try {
    return execFileSync("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", infoPlistPath], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
};

const title = plistValue("CFBundleDisplayName") || plistValue("CFBundleName");
if (!title) throw new Error(`No CFBundleDisplayName or CFBundleName in ${infoPlistPath}`);

const iconName = plistValue("CFBundleIconFile").replace(/\.icns$/, "");
const icon = iconName ? await composeIcon(path.join(appPath, "Contents/Resources", `${iconName}.icns`)) : undefined;

rmSync(dmgPath, { force: true });

await new Promise((resolve, reject) => {
  const build = appdmg({
    target: dmgPath,
    basepath: process.cwd(),
    specification: {
      title,
      icon,
      background,
      "icon-size": 160,
      format: "ULFO",
      filesystem: "APFS",
      window: { size: { width: 660, height: 400 } },
      contents: [
        { x: 180, y: 170, type: "file", path: path.resolve(appPath) },
        { x: 480, y: 170, type: "link", path: "/Applications" },
      ],
    },
  });
  build.on("progress", (info) => {
    if (info.type === "step-begin") console.log(`create-dmg: ${info.title}`);
  });
  build.on("finish", resolve);
  build.on("error", reject);
});

if (!existsSync(dmgPath)) throw new Error(`appdmg finished without writing ${dmgPath}`);

execFileSync("/usr/bin/codesign", ["--sign", identity, dmgPath], { stdio: "inherit" });
// codesign --display reports on stderr
const signature = spawnSync("/usr/bin/codesign", ["--display", "--verbose=2", dmgPath], { encoding: "utf8" }).stderr;
console.log(`create-dmg: signed ${path.basename(dmgPath)}`);
if (identity !== "-" && !/^Authority=/m.test(signature)) {
  throw new Error(`${dmgPath} is not signed by a certificate authority`);
}
