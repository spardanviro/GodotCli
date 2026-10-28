/**
 * MCP resources: the read commands, reachable by address, so that a client
 * can attach the scene tree, a node, a file or a class to a conversation
 * without the model calling a tool. Each one is a read command underneath.
 */

export interface ResourceEntry {
  /** A fixed address, or a template with one {placeholder}. */
  readonly uri: string;
  readonly name: string;
  readonly description: string;
  /** The read command (or gd_* tool) that answers it. */
  readonly command: string;
  /** Its arguments, given what stood for the placeholder. */
  readonly args: (value: string) => Readonly<Record<string, unknown>>;
}

const none = (): Readonly<Record<string, unknown>> => ({});

export const RESOURCES: readonly ResourceEntry[] = [
  { uri: "godot://editor/status", name: "Editor status", description: "Godot version, project, edited scene, play state, access mode.", command: "editor_status", args: none },
  { uri: "godot://scene/tree", name: "Scene tree", description: "Node tree of the scene being edited.", command: "scene_tree", args: none },
  { uri: "godot://scene/selection", name: "Selection", description: "Nodes selected in the editor.", command: "editor_selection", args: none },
  { uri: "godot://editor/errors", name: "Editor errors", description: "Errors and warnings the editor printed (Godot 4.5+).", command: "editor_errors", args: none },
  { uri: "godot://project/input-map", name: "Input map", description: "The project's input actions and their events.", command: "project_input_map", args: none },
  { uri: "godot://game/tree", name: "Running game tree", description: "Node tree of the game the editor is running.", command: "game_tree", args: none },
  { uri: "godot://game/performance", name: "Running game performance", description: "Frame rate, frame times, memory, nodes, draw calls of the running game.", command: "game_performance", args: none },
];

export const RESOURCE_TEMPLATES: readonly ResourceEntry[] = [
  { uri: "godot://node/{path}", name: "Node", description: "Class, script, groups and Inspector properties of a node of the edited scene; path relative to the scene root.", command: "node_get", args: (path) => ({ path }) },
  { uri: "godot://file/{path}", name: "Project file", description: "A text file of the project; path without res://.", command: "fs_read_text", args: (path) => ({ path: `res://${path}` }) },
  { uri: "godot://resource/{path}", name: "Resource file", description: "Class and properties of a .tres or .res file; path without res://.", command: "resource_get", args: (path) => ({ path: `res://${path}` }) },
  { uri: "godot://class/{name}", name: "Engine class", description: "Properties, methods, signals and constants of a class of the installed Godot.", command: "gd_api_class", args: (name) => ({ name }) },
];

/** The entry for an address, with its arguments; undefined for an address that names nothing. */
export function resolveResource(uri: string): { entry: ResourceEntry; args: Readonly<Record<string, unknown>> } | undefined {
  const fixed = RESOURCES.find((entry) => entry.uri === uri);
  if (fixed !== undefined) {
    return { entry: fixed, args: fixed.args("") };
  }
  for (const entry of RESOURCE_TEMPLATES) {
    const prefix = entry.uri.slice(0, entry.uri.indexOf("{"));
    if (uri.startsWith(prefix) && uri.length > prefix.length) {
      let value: string;
      try {
        value = decodeURIComponent(uri.slice(prefix.length));
      } catch {
        return undefined;
      }
      // A placeholder is one value, not a way to add options or climb out
      // (the bridge checks paths too; this keeps the address plain).
      const segments = value.split("/");
      if (value === "" || value.startsWith("-") || /[\0\\]|:\/\//u.test(value) || value.startsWith("/") || segments.includes("..") || segments.includes(".")) {
        return undefined;
      }
      return { entry, args: entry.args(value) };
    }
  }
  return undefined;
}

export function listed(entry: ResourceEntry): Record<string, string> {
  return { name: entry.name, description: entry.description, mimeType: "application/json" };
}
