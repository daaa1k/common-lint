#!/usr/bin/env node
/**
 * Writes a merged commitlint config (common-lint base + optional repo config) to
 * /tmp and prints the path for `commitlint --config`.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { loadConfig } from "@commitlint/load/lib/utils/load-config.js";
import mergeWith from "lodash.mergewith";

const require = createRequire(import.meta.url);
const OUT = "/tmp/commitlint-common-lint-merged.cjs";

function resolveBaseConfigPath() {
  if (process.env.COMMITLINT_COMMON_BASE) {
    return process.env.COMMITLINT_COMMON_BASE;
  }
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    "/opt/common-lint/commitlint.config.cjs",
    path.join(here, "commitlint.config.cjs"),
    path.join(here, "..", "commitlint.config.cjs"),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      return path.resolve(p);
    }
  }
  return null;
}

const cwd = process.env.GITHUB_WORKSPACE;
if (!cwd) {
  console.error("GITHUB_WORKSPACE is not set");
  process.exit(1);
}

const BASE = resolveBaseConfigPath();
if (!BASE) {
  console.error(
    "Could not find bundled commitlint.config.cjs (set COMMITLINT_COMMON_BASE if needed).",
  );
  process.exit(1);
}

const baseRaw = require(BASE);
const loaded = await loadConfig(cwd);
let userRaw = {};
if (loaded) {
  const c = loaded.config;
  userRaw = typeof c === "function" ? await c() : await c;
}

const merged = mergeWith({}, baseRaw, userRaw, (objValue, srcValue, key) => {
  if (key === "extends" || key === "plugins") {
    const a = Array.isArray(objValue) ? objValue : objValue ? [objValue] : [];
    const b = Array.isArray(srcValue) ? srcValue : srcValue ? [srcValue] : [];
    return [...new Set([...a, ...b])];
  }
});

let body;
try {
  body = `module.exports = ${JSON.stringify(merged, null, 2)};\n`;
} catch (err) {
  console.error(
    "Failed to serialize merged commitlint config (non-JSON-serializable values?).",
    err,
  );
  process.exit(1);
}

fs.writeFileSync(OUT, body, "utf8");
console.log(OUT);
