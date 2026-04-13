/**
 * Build script: transpile js/src/index.deno.ts → js/dist/index.deno.js
 *
 * Run: deno run --allow-read --allow-write scripts/build-deno.ts
 */
import { transpile } from "jsr:@deno/emit";

const srcUrl = new URL("../js/src/index.deno.ts", import.meta.url);
const outPath = new URL("../js/dist/index.deno.js", import.meta.url);

console.log("Building", srcUrl.pathname, "→", outPath.pathname);

const result = await transpile(srcUrl);
const code = result.get(srcUrl.href);

if (!code) {
  console.error("emit failed: no output for", srcUrl.href);
  console.error("Available keys:", [...result.keys()]);
  Deno.exit(1);
}

// Deno.emit outputs the original file URL as key; strip source map comment
// to keep the output clean for npm distribution.
const stripped = code.replace(/^\/\/# sourceMappingURL=.*$/m, "").trimEnd() + "\n";

await Deno.writeTextFile(outPath, stripped);
console.log("OK:", outPath.pathname, `(${stripped.length} bytes)`);
