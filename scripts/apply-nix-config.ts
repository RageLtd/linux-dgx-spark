#!/usr/bin/env bun
/**
 * apply-nix-config.ts
 *
 * Reads the kernel config delta from nixos-dgx-spark and applies it
 * to the current kernel .config using the kernel's scripts/config utility.
 *
 * Handles both formats used by the nixos-dgx-spark repo:
 *   .nix  - Nix attribute set with kernelConfig options
 *   .config - plain defconfig-style fragment
 *
 * Usage:
 *   bun scripts/apply-nix-config.ts --nix-config <path> --kernel-src <path>
 */

import { readFileSync } from "fs";
import { join } from "path";
import { spawnSync } from "child_process";

// ---------------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
const get = (flag: string): string => {
  const i = args.indexOf(flag);
  if (i === -1 || !args[i + 1]) {
    console.error(`ERROR: Missing required argument: ${flag}`);
    process.exit(1);
  }
  return args[i + 1];
};

const nixConfigPath = get("--nix-config");
const kernelSrc = get("--kernel-src");

// ---------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------

type ConfigMap = Map<string, string>;

/**
 * Parse a .nix kernel config file from nixos-dgx-spark.
 *
 * The 6.17+ format uses Nix lib.kernel values:
 *   "OPTION_NAME" = lib.mkForce yes;          -> CONFIG_OPTION_NAME=y
 *   "OPTION_NAME" = lib.mkForce no;           -> # CONFIG_OPTION_NAME is not set
 *   "OPTION_NAME" = lib.mkForce module;        -> CONFIG_OPTION_NAME=m
 *   "OPTION_NAME" = lib.mkForce (freeform "v"); -> CONFIG_OPTION_NAME=v
 */
function parseNixConfig(text: string): ConfigMap {
  const configs: ConfigMap = new Map();
  const nixValueMap: Record<string, string> = { yes: "y", no: "n", module: "m" };

  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#") || trimmed.startsWith("{") || trimmed === "}") continue;

    // Match both quoted and unquoted names:
    //   "6LOWPAN_FOO" = lib.mkForce yes;    (names starting with digits must be quoted in Nix)
    //   ACPI_DOCK = lib.mkForce module;      (most names are unquoted)
    const m = trimmed.match(/^(?:"([^"]+)"|(\w+))\s*=\s*lib\.mkForce\s+(.+);$/);
    if (!m) continue;

    const key = `CONFIG_${m[1] ?? m[2]}`;
    const rawVal = m[3].trim();

    // yes / no / module
    if (rawVal in nixValueMap) {
      configs.set(key, nixValueMap[rawVal]);
      continue;
    }

    // (freeform "value")
    const freeform = rawVal.match(/^\(freeform\s+"([^"]*)"\)$/);
    if (freeform) {
      configs.set(key, freeform[1]);
      continue;
    }

    console.warn(`Warning: unrecognized value for ${key}: ${rawVal}`);
  }

  return configs;
}

/**
 * Parse a plain defconfig fragment.
 *
 * Handles:
 *   CONFIG_FOO=y
 *   CONFIG_FOO=m
 *   CONFIG_FOO="some string"
 *   # CONFIG_FOO is not set
 */
function parseDefconfig(text: string): ConfigMap {
  const configs: ConfigMap = new Map();
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;

    const notSet = line.match(/^#\s*(CONFIG_\w+) is not set$/);
    if (notSet) {
      configs.set(notSet[1], "n");
      continue;
    }

    if (line.startsWith("#")) continue;

    const kv = line.match(/^(CONFIG_\w+)=(.*)$/);
    if (kv) {
      configs.set(kv[1], kv[2].replace(/^"|"$/g, ""));
    }
  }
  return configs;
}

// ---------------------------------------------------------------------------
// Apply via kernel's scripts/config
// ---------------------------------------------------------------------------

/**
 * Invoke scripts/config in batches to avoid ARG_MAX limits.
 * Each option maps to one or more flags:
 *   y  -> --enable KEY
 *   m  -> --module KEY
 *   n  -> --disable KEY
 *   *  -> --set-val KEY VALUE
 */
function applyConfigs(configs: ConfigMap): void {
  const scriptsConfig = join(kernelSrc, "scripts", "config");

  // Build list of argument groups — each group is a complete command
  // scripts/config expects names WITHOUT CONFIG_ prefix — it adds it itself
  const groups: string[][] = [];
  for (const [rawKey, val] of configs) {
    const key = rawKey.replace(/^CONFIG_/, "");
    switch (val) {
      case "y":  groups.push(["--enable",  key]); break;
      case "m":  groups.push(["--module",  key]); break;
      case "n":  groups.push(["--disable", key]); break;
      default:   groups.push(["--set-val", key, val]); break;
    }
  }

  // Chunk by complete groups to avoid splitting flag+key pairs
  const BATCH = 100; // config entries per invocation

  for (let i = 0; i < groups.length; i += BATCH) {
    const batch = groups.slice(i, i + BATCH);
    const args = batch.flat();
    const result = spawnSync(scriptsConfig, args, {
      cwd: kernelSrc,
      stdio: ["ignore", "inherit", "pipe"],
      encoding: "utf8",
    });

    if (result.status !== 0) {
      console.warn(`Warning: scripts/config exited ${result.status}:`);
      if (result.stderr) console.warn(result.stderr.trim());
    }
  }

  console.log(`Applied ${configs.size} config options.`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const text = readFileSync(nixConfigPath, "utf8");
const isNix = nixConfigPath.endsWith(".nix");

console.log(`Parsing ${isNix ? "Nix" : "defconfig"} format: ${nixConfigPath}`);
const configs = isNix ? parseNixConfig(text) : parseDefconfig(text);

if (configs.size === 0) {
  console.error("ERROR: No config options parsed - check the file format.");
  console.error("Preview:", text.slice(0, 400));
  process.exit(1);
}

console.log(`Parsed ${configs.size} config options.`);
applyConfigs(configs);
