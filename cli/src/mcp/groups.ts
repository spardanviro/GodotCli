/**
 * Tool groups for `gd mcp --tools`: a client with a cap on the number of
 * tools, or a model with a small context, gets only the groups it needs.
 * Every tool belongs to exactly one group, found from its name.
 */

export const TOOL_GROUPS = ["core", "game", "animation", "level", "import", "docs", "test", "exec", "custom"] as const;
export type ToolGroup = (typeof TOOL_GROUPS)[number];

const DESCRIPTIONS: Readonly<Record<ToolGroup, string>> = {
  core: "scenes, nodes, files, resources, project settings, the editor, undo, gd_run, gd_check, gd_status, gd_doctor, the headless host",
  game: "the running game and its debugger (game_*)",
  animation: "animation players, state machines, blend spaces, sprite frames",
  level: "tile sets, tile maps, navigation",
  import: "import settings",
  docs: "the engine's API and the manual (gd_api_*, gd_docs_*)",
  test: "the project's GUT or gdUnit4 tests (gd_test)",
  exec: "eval: GDScript in the editor, when the user has enabled it",
  custom: "the project's own commands (res://gdcli_commands/)",
};

/** Names that are not the plain prefix rule below. */
const BY_NAME: Readonly<Record<string, ToolGroup>> = {
  eval: "exec",
  batch: "core",
  preset_create: "core",
  gd_test: "test",
  gd_api_class: "docs",
  gd_api_search: "docs",
  gd_docs_search: "docs",
  gd_docs_page: "docs",
  navigation_bake: "level",
  sprite_frames_create: "animation",
};

const BY_PREFIX: readonly (readonly [string, ToolGroup])[] = [
  ["game_", "game"],
  ["animation_", "animation"],
  ["tileset_", "level"],
  ["tilemap_", "level"],
  ["gridmap_", "level"],
  ["theme_", "core"],
  ["import_", "import"],
  ["collision_", "core"],
  ["scene_", "core"],
  ["node_", "core"],
  ["fs_", "core"],
  ["resource_", "core"],
  ["project_", "core"],
  ["editor_", "core"],
  ["edit_", "core"],
  ["host_", "core"],
  ["gd_", "core"],
];

export function groupOf(name: string, custom = false): ToolGroup {
  if (custom) {
    return "custom";
  }
  const named = BY_NAME[name];
  if (named !== undefined) {
    return named;
  }
  return BY_PREFIX.find(([prefix]) => name.startsWith(prefix))?.[1] ?? "custom";
}

/** The groups listed in `--tools` ("core,game" or "all"), or a message saying what is wrong. */
export function parseToolGroups(text: string): ReadonlySet<ToolGroup> | string {
  const names = text
    .split(",")
    .map((name) => name.trim().toLowerCase())
    .filter((name) => name !== "");
  if (names.length === 0) {
    return `--tools takes group names separated by commas, or all: ${TOOL_GROUPS.join(", ")}.`;
  }
  const unknown = names.filter((name) => name !== "all" && !(TOOL_GROUPS as readonly string[]).includes(name));
  if (unknown.length > 0) {
    return `Unknown tool group ${unknown.join(", ")}. The groups: ${TOOL_GROUPS.map((group) => `${group} (${DESCRIPTIONS[group]})`).join("; ")}.`;
  }
  if (names.includes("all")) {
    return new Set(TOOL_GROUPS);
  }
  return new Set(names as ToolGroup[]);
}
