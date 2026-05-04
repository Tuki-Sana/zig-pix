import { readFileSync, writeFileSync, chmodSync } from "fs";

const file = "js/dist/cli.js";
const src = readFileSync(file, "utf8");
if (!src.startsWith("#!/")) {
  writeFileSync(file, "#!/usr/bin/env node\n" + src);
}
chmodSync(file, 0o755);
