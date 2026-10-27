import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

/** Files Godot writes next to scripts and assets by itself: not part of the bridge as shipped. */
const GENERATED = /\.(uid|import)$/iu;
/** More files than the bridge has; a folder past this is not the bridge. */
const MAX_FILES = 2000;
const VERSION_LINE = /^version="([^"]+)"/mu;

const digests = new Map<string, string | undefined>();

/**
 * One hash over the files of an addon folder (paths and contents, in a fixed
 * order), or undefined when it cannot be read. Links are not followed.
 */
export function addonDigest(folder: string): string | undefined {
  const hash = createHash("sha256");
  const files: string[] = [];
  const walk = (directory: string): boolean => {
    let names: string[];
    try {
      names = readdirSync(directory).sort();
    } catch {
      return false;
    }
    for (const name of names) {
      const path = join(directory, name);
      const stat = lstatSync(path);
      if (stat.isDirectory()) {
        if (!walk(path)) {
          return false;
        }
      } else if (stat.isFile() && !GENERATED.test(name)) {
        files.push(path);
        if (files.length > MAX_FILES) {
          return false;
        }
      }
    }
    return true;
  };
  if (!walk(folder)) {
    return undefined;
  }
  for (const file of files) {
    hash.update(relative(folder, file).replaceAll("\\", "/"));
    hash.update("\0");
    // Line endings as a checkout may have changed them.
    hash.update(readFileSync(file, "utf8").replaceAll("\r\n", "\n"));
    hash.update("\0");
  }
  return hash.digest("hex");
}

function versionOf(folder: string): string | undefined {
  try {
    return VERSION_LINE.exec(readFileSync(join(folder, "plugin.cfg"), "utf8"))?.[1];
  } catch {
    return undefined;
  }
}

/**
 * True when a project's bridge claims the version gd ships but is not that
 * copy. A different version is expected to differ; the same version with
 * other code is either a local change or a project shipping its own bridge,
 * which the access modes cannot hold to anything.
 */
export function addonDiffersFromBundled(bundledFolder: string, installedFolder: string): boolean {
  const version = versionOf(installedFolder);
  if (version === undefined || version !== versionOf(bundledFolder)) {
    return false;
  }
  if (!digests.has(bundledFolder)) {
    digests.set(bundledFolder, addonDigest(bundledFolder));
  }
  const bundled = digests.get(bundledFolder);
  return bundled !== undefined && addonDigest(installedFolder) !== bundled;
}

export const CHANGED_BRIDGE_WARNING =
  "This project's bridge (addons/gdcli) has gd's version number but not gd's code. A changed bridge is not held to the access modes. If you did not change it, run `gd bridge install --force`.";
