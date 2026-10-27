// Fills the reference files of the plugin's domain skills from the knowledge
// base of the native module (spardanviro/Godot_AI, modules/ai_assistant/knowledge):
// the pitfalls in gotchas.md and the class notes in api_docs.md, sorted by topic.
//
//   node scripts/import-knowledge.mjs <path to .../ai_assistant/knowledge>
//
// The result is committed; run this again when the native module's knowledge
// base changes. Entries written for the native module's own way of working
// (code blocks that the module runs, its tool names) are left out.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { applyCorrections } from "./knowledge-corrections.mjs";

const SKILLS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "plugin", "skills");
const DEFAULT_TOPIC = "godot-gdscript";

/**
 * Topics in order of precedence on a tie. A pattern is matched against the
 * title and the keywords of an entry: each distinct match in the title is
 * two points, in the keywords one.
 * @type {ReadonlyArray<{ skill: string, title: string, pattern: RegExp }>}
 */
const TOPICS = [
  {
    skill: "godot-animation-audio",
    title: "animation, tweens, particles and audio",
    pattern: /anim|tween|audio|sound|music|particle|skeleton|\bbone|blend ?(space|tree)|ogg|wav\b|mp3|microphone|doppler|reverb/giu,
  },
  {
    skill: "godot-ui",
    title: "user interface",
    pattern: /\bcontrol\b|\w+container\b|anchor|\blabel\b|button|theme|\bfont|locali[sz]|translat|\bgui\b|richtext|stylebox|focus|tooltip|canvaslayer|lineedit|textedit|\bbbcode|\bui\b|hud|popup|\bwindow|stretch|resolution|fullscreen|dpi/giu,
  },
  {
    skill: "godot-3d-rendering",
    title: "3D scenes, rendering, materials, shaders and importing assets",
    pattern:
      /\b3d\b|mesh|light|shader|material|render|camera3d|environment|shadow|\bgi\b|\blod\b|occlusion|import|blender|gltf|texture|viewport|decal|\bfog|\bsky|csg|voxel|sdfgi|lightmap|compute|forward|compatibility|mobile renderer|hdr|tonemap|transparen|z-fight|gridmap|\bxr\b|vulkan|opengl/giu,
  },
  {
    skill: "godot-physics-gameplay",
    title: "physics, movement, input, navigation and tile maps",
    pattern:
      /physics|collision|rigidbody|characterbody|staticbody|\bbody|raycast|\bray\b|\barea[23]?d?\b|joint|navigation|pathfinding|navmesh|tilemap|tileset|\btile|\binput|move_and_slide|move_and_collide|velocity|joypad|controller|mouse|keyboard|touch|camera2d|parallax|projectile|multiplayer|\brpc\b/giu,
  },
  {
    skill: DEFAULT_TOPIC,
    title: "GDScript, nodes, scenes, resources, files, threads and platforms",
    pattern:
      /gdscript|thread|mutex|signal|resource|autoload|@export|@tool|@onready|preload|\bload\b|json|\bfile|variant|array|dictionary|\benum|lambda|await|coroutine|_ready|_init|queue_free|scene ?tree|instantiate|packedscene|web export|android|\bios\b|c#|gdextension|editor ?plugin|\bgroup|setter|getter|static|typed|class_name|\bnode\b/giu,
  },
];

/** Where the notes of a class go; a class that is not listed goes to the default topic. */
const CLASS_TOPICS = new Map(
  Object.entries({
    "godot-physics-gameplay":
      "CharacterBody3D CharacterBody2D RigidBody3D RigidBody2D Area3D Area2D CollisionShape3D CollisionShape2D RayCast3D RayCast2D NavigationAgent3D NavigationAgent2D NavigationRegion3D TileMapLayer TileMap Camera2D PathFollow2D",
    "godot-3d-rendering":
      "Camera3D ShaderMaterial StandardMaterial3D MultiMesh MultiMeshInstance3D SubViewport Node3D WorldEnvironment DirectionalLight3D GridMap PathFollow3D",
    "godot-animation-audio": "AnimationPlayer AnimationTree AudioStreamPlayer AudioStreamPlayer2D AudioStreamPlayer3D Tween GPUParticles3D GPUParticles2D Skeleton3D",
    "godot-ui": "Control Button LineEdit RichTextLabel Label",
  }).flatMap(([skill, names]) => names.split(" ").map((name) => [name, skill])),
);

// Written for code the native module runs inside the editor, or for its tools.
const NATIVE_ONLY = /EditorScript|run_editor_script|write_file|create_node|set_node_properties|attach_script\b|WRITE_MEMORY|godot_ai/u;

/**
 * @param {string} text
 * @param {RegExp} pattern
 * @returns {number} distinct matches
 */
function matches(text, pattern) {
  return new Set((text.match(pattern) ?? []).map((match) => match.toLowerCase())).size;
}

/**
 * @param {string} title
 * @param {string} keywords
 * @returns {string}
 */
function topicOf(title, keywords) {
  let best = DEFAULT_TOPIC;
  let bestScore = 0;
  for (const topic of TOPICS) {
    const score = 2 * matches(title, topic.pattern) + matches(keywords, topic.pattern);
    if (score > bestScore) {
      best = topic.skill;
      bestScore = score;
    }
  }
  return best;
}

/**
 * @param {string} source gotchas.md
 * @returns {{ keywords: string, title: string, body: string }[]}
 */
function parseGotchas(source) {
  const parts = source.replaceAll("\r\n", "\n").split(/^<!-- keywords: (.*?) -->\n/mu);
  const entries = [];
  for (let index = 1; index < parts.length; index += 2) {
    const body = (parts[index + 1] ?? "").trim();
    const title = /^### (.+)$/mu.exec(body)?.[1] ?? "";
    entries.push({ keywords: parts[index] ?? "", title, body });
  }
  return entries;
}

/**
 * @param {string} source api_docs.md
 * @returns {{ name: string, body: string }[]}
 */
function parseApi(source) {
  const parts = source.replaceAll("\r\n", "\n").split(/^## (.+)\n/mu);
  const sections = [];
  for (let index = 1; index < parts.length; index += 2) {
    sections.push({ name: (parts[index] ?? "").trim(), body: (parts[index + 1] ?? "").trimEnd() });
  }
  return sections;
}

function write(skill, name, text) {
  const path = join(SKILLS_DIR, skill, "references", name);
  mkdirSync(dirname(path), { recursive: true });
  // Statements the audit found wrong are corrected on every import.
  writeFileSync(path, applyCorrections(`${skill}/references/${name}`, text));
}

function main() {
  const knowledgeDir = process.argv[2];
  if (knowledgeDir === undefined) {
    process.stderr.write("usage: node scripts/import-knowledge.mjs <path to ai_assistant/knowledge>\n");
    process.exit(2);
  }
  const titles = new Map(TOPICS.map((topic) => [topic.skill, topic.title]));

  /** @type {Map<string, string[]>} */
  const gotchas = new Map([...titles.keys()].map((skill) => [skill, []]));
  const seen = new Set();
  let skipped = 0;
  for (const entry of parseGotchas(readFileSync(join(knowledgeDir, "gotchas.md"), "utf8"))) {
    const key = entry.title.toLowerCase().replace(/[^a-z0-9]+/gu, " ").trim();
    if (entry.title === "" || seen.has(key) || NATIVE_ONLY.test(entry.body)) {
      skipped += 1;
      continue;
    }
    seen.add(key);
    gotchas.get(topicOf(entry.title, entry.keywords))?.push(`<!-- keywords: ${entry.keywords} -->\n${entry.body}`);
  }

  /** @type {Map<string, string[]>} */
  const api = new Map([...titles.keys()].map((skill) => [skill, []]));
  for (const section of parseApi(readFileSync(join(knowledgeDir, "api_docs.md"), "utf8"))) {
    api.get(CLASS_TOPICS.get(section.name) ?? DEFAULT_TOPIC)?.push(`## ${section.name}\n${section.body}`);
  }

  for (const [skill, title] of titles) {
    const entries = gotchas.get(skill) ?? [];
    write(
      skill,
      "gotchas.md",
      [
        `# Pitfalls: ${title}`,
        "",
        `${entries.length} entries, each a mistake that is easy to make in Godot 4 and what to do instead. Do not read this file from top to bottom:`,
        "search it for the class, method or term you are about to use (the `keywords` line of each entry lists them) and read the entries that match.",
        "The other skills of this plugin have a file like this one for their topics: `../../*/references/gotchas.md` searches all of them.",
        "",
        "Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.",
        "",
        entries.join("\n\n\n"),
        "",
      ].join("\n"),
    );
    const sections = api.get(skill) ?? [];
    write(
      skill,
      "api.md",
      [
        `# Class notes: ${title}`,
        "",
        "Members that are used most and the notes that matter, one section per class. This is a reminder, not the documentation:",
        "`gd api class <Name>` and `gd api class <Name> --member <member>` print the reference of the Godot version that is installed, and they win where the two differ.",
        "",
        "Imported from the knowledge base of the Godot AI assistant module (github.com/spardanviro/Godot_AI) by `scripts/import-knowledge.mjs`; do not edit by hand.",
        "",
        sections.join("\n\n"),
        "",
      ].join("\n"),
    );
    process.stdout.write(`${skill}: ${entries.length} pitfalls, ${sections.length} classes\n`);
  }
  process.stdout.write(`left out: ${skipped} (duplicates and entries written for the native module)\n`);
}

main();
