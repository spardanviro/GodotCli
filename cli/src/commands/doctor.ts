import { readFileSync } from "node:fs";
import { join } from "node:path";

import { addonDiffersFromBundled } from "../addon-digest.js";
import { handshake } from "../client.js";
import type { CommandHandler } from "../context.js";
import { isEnvelopeError, success } from "../envelope.js";
import { requireGodot } from "../godot.js";
import { readInstances } from "../instances.js";
import { PROJECT_FILE, findProject, gdcliHome, sameLocation } from "../project.js";
import { sanitize } from "../text.js";
import { ADDON_RELATIVE_DIR, isPluginEnabled, readPluginVersion } from "./bridge.js";

interface Check {
  readonly name: string;
  readonly ok: boolean;
  readonly detail: string;
  readonly hint?: string;
}

/** `gd doctor`: what works, what does not, and what to do about it. Never fails by itself. */
export const doctorCommand: CommandHandler = async (context, globals) => {
  const checks: Check[] = [{ name: "gd", ok: true, detail: `${context.readVersion()} on Node ${process.versions.node}` }];

  const godot = await requireGodot(context, globals);
  checks.push(
    isEnvelopeError(godot)
      ? { name: "godot", ok: false, detail: godot.message, ...(godot.hint === undefined ? {} : { hint: godot.hint }) }
      : { name: "godot", ok: true, detail: `${godot.version.text} at ${godot.bin}` },
  );

  const project = findProject(context, globals);
  if (typeof project !== "string") {
    checks.push({ name: "project", ok: false, detail: project.message, ...(project.hint === undefined ? {} : { hint: project.hint }) });
  } else {
    checks.push({ name: "project", ok: true, detail: project });

    const installed = readPluginVersion(join(project, ADDON_RELATIVE_DIR));
    const enabled = isPluginEnabled(readFileSync(join(project, PROJECT_FILE), "utf8"));
    const bundled = readPluginVersion(context.addonDir);
    const changed = addonDiffersFromBundled(context.addonDir, join(project, ADDON_RELATIVE_DIR));
    const current = installed !== undefined && installed === bundled && !changed;
    checks.push({
      name: "bridge",
      ok: installed !== undefined && enabled,
      detail:
        installed === undefined
          ? "not installed"
          : `${installed}${enabled ? "" : ", not enabled"}${changed ? ", but not gd's code" : current ? "" : `, gd ships ${bundled ?? "?"}`}`,
      ...(installed !== undefined && enabled && current ? {} : { hint: "Run `gd bridge install` (add --force to replace another version or a changed copy)." }),
    });

    const instances = readInstances(gdcliHome(context), context.platform).filter((instance) =>
      sameLocation(instance.projectPath, project, context.platform),
    );
    const states = [];
    for (const instance of instances) {
      states.push((await handshake(instance)).state);
    }
    const reachable = states.includes("ready");
    checks.push({
      name: "editor",
      ok: reachable,
      detail: states.length === 0 ? "no editor with the bridge is running for this project" : states.join(", "),
      ...(reachable
        ? {}
        : { hint: "Open the project with `gd open`. An editor started with --recovery-mode does not load plugins, so the bridge stays off." }),
    });
  }

  const problems = checks.filter((check) => !check.ok).length;
  const lines = checks.map((check) => `${check.ok ? "ok  " : "FAIL"} ${check.name}: ${check.detail}${check.hint === undefined ? "" : `\n     ${check.hint}`}`);
  return { envelope: success("doctor", { checks, problems }), human: `${sanitize(lines.join("\n"))}\n` };
};
