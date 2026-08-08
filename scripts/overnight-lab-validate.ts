import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const root = process.cwd();
const lab = join(root, ".context/overnight-lab");

async function markdownFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return markdownFiles(path);
    return entry.isFile() && entry.name.endsWith(".md") ? [path] : [];
  }));
  return nested.flat();
}

const files = await markdownFiles(lab);
const ids = new Set<string>();
for (const file of files) {
  const content = await readFile(file, "utf8");
  for (const match of content.matchAll(/\bWI-\d{3}\b/g)) ids.add(match[0]);
}

const expected = [...ids].sort();
if (ids.size > 100) throw new Error(`work item cap exceeded: ${ids.size}/100`);
if (expected.some((id, index) => id !== `WI-${String(index + 1).padStart(3, "0")}`)) {
  throw new Error(`work item IDs are not contiguous: ${expected.join(", ")}`);
}

console.log(JSON.stringify({ workItems: ids.size, cap: 100, remaining: 100 - ids.size }));
