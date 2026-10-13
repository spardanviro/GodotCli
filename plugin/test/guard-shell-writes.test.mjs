import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import { commandWrites, decide, parse, splitHeredocs } from "../hooks/guard-shell-writes.mjs";

const HOOK = join(dirname(fileURLToPath(import.meta.url)), "..", "hooks", "guard-shell-writes.mjs");
const folders = [];

after(() => {
  for (const folder of folders) {
    rmSync(folder, { recursive: true, force: true });
  }
});

/** A Godot project with the bridge in `game`, next to a `scratch` folder. */
function workspace({ bridge = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "gdcli-shell-"));
  folders.push(root);
  const project = join(root, "game");
  mkdirSync(join(project, "scripts"), { recursive: true });
  mkdirSync(join(root, "scratch"));
  writeFileSync(join(project, "project.godot"), "config_version=5\n");
  if (bridge) {
    mkdirSync(join(project, "addons", "gdcli"), { recursive: true });
    writeFileSync(join(project, "addons", "gdcli", "plugin.cfg"), "[plugin]\n");
  }
  return { root, project };
}

describe("parse", () => {
  test("splits commands and sets redirection targets apart", () => {
    assert.deepEqual(parse("echo hi > out.txt && cat a | tee -a b; ls"), [
      { words: ["echo", "hi"], redirects: ["out.txt"] },
      { words: ["cat", "a"], redirects: [] },
      { words: ["tee", "-a", "b"], redirects: [] },
      { words: ["ls"], redirects: [] },
    ]);
  });

  test("keeps quoted text together and does not take what is inside for syntax", () => {
    assert.deepEqual(parse(`printf 'a > b; c' >> "my file.gd"`), [{ words: ["printf", "a > b; c"], redirects: ["my file.gd"] }]);
    assert.deepEqual(parse('echo "say \\"hi\\""'), [{ words: ["echo", 'say "hi"'], redirects: [] }]);
  });

  test("does not take a descriptor for a file", () => {
    assert.deepEqual(parse("make 2>&1 | head"), [
      { words: ["make"], redirects: [] },
      { words: ["head"], redirects: [] },
    ]);
    assert.deepEqual(parse("make 2> errors.log"), [{ words: ["make"], redirects: ["errors.log"] }]);
    assert.deepEqual(parse("make &> all.log"), [{ words: ["make"], redirects: ["all.log"] }]);
    assert.deepEqual(parse("echo x >| out.txt"), [{ words: ["echo", "x"], redirects: ["out.txt"] }]);
    assert.deepEqual(parse("echo x >&2"), [{ words: ["echo", "x"], redirects: [] }]);
  });

  test("takes an escaped quote for a character, and a backslash in a path for itself", () => {
    assert.deepEqual(parse("echo it\\'s; rm a.gd"), [
      { words: ["echo", "it's"], redirects: [] },
      { words: ["rm", "a.gd"], redirects: [] },
    ]);
    assert.deepEqual(parse("type scripts\\player.gd"), [{ words: ["type", "scripts\\player.gd"], redirects: [] }]);
  });
});

describe("splitHeredocs", () => {
  test("takes the body out and keeps the rest of the line and what follows", () => {
    const split = splitHeredocs("cat <<'EOF' > out.gd\nextends Node\nEOF\nrm other.gd");

    assert.equal(split.command, "cat   > out.gd\nrm other.gd");
    assert.deepEqual(split.heredocs, [{ head: "cat   > out.gd", body: "extends Node" }]);
  });

  test("leaves a here-string alone", () => {
    assert.deepEqual(splitHeredocs('cat <<< "hi" > out.gd'), { command: 'cat <<< "hi" > out.gd', heredocs: [] });
  });
});

describe("commandWrites", () => {
  test("refuses the ordinary ways of writing a project script", () => {
    const { project } = workspace();
    for (const command of [
      "echo 'extends Node' > scripts/player.gd",
      "cat draft.gd >> scripts/player.gd",
      "printf x | tee scripts/player.gd",
      "cp ../scratch/player.gd scripts/player.gd",
      "cp ../scratch/player.gd scripts/",
      "cp -t scripts ../scratch/player.gd",
      "mv ../scratch/player.gd scripts/enemy.gd",
      "rm scripts/player.gd",
      "rm -rf addons/other",
      "sed -i 's/a/b/' scripts/player.gd",
      "sed --in-place=.bak s/a/b/ project.godot",
      "perl -pi -e 's/a/b/' scenes/main.tscn",
      "touch scripts/new.gd",
      "dd if=/dev/zero of=scripts/player.gd",
      "git checkout -- scripts/player.gd",
      "git restore project.godot",
      "sudo rm scripts/player.gd",
      "FOO=1 rtk cp x.gd scripts/y.gd",
      "ls && (cd scripts && echo x > player.gd)",
      "cd scripts; echo x > player.gd",
      "Set-Content -Path scripts/player.gd -Value 'extends Node'",
      "'extends Node' | Out-File scripts/player.gd",
      "Copy-Item ..\\scratch\\player.gd -Destination scripts\\player.gd",
      "Remove-Item scripts\\player.gd",
      "New-Item scripts/enemy.gd",
      "echo x > scripts/Player.cs",
      "cat <<'EOF' > scripts/player.gd\nextends Node\nEOF",
      "cat <<EOF > ../scratch/x.gd\nextends Node\nEOF\ncp ../scratch/x.gd scripts/x.gd",
      'cat <<< "extends Node" > scripts/player.gd',
      "echo x >| project.godot",
      "echo it\\'s; rm scripts/player.gd",
      "mv ../scratch/main.tscn scenes/",
      "cp --target-directory=scripts ../scratch/player.gd",
      "for f in a b; do cp ../scratch/$f.gd scripts/x.gd; done",
      "copy ..\\scratch\\player.gd scripts\\player.gd /Y",
      "xcopy ..\\scratch\\player.gd scripts\\ /Y",
      "robocopy ..\\scratch scripts player.gd",
      "git -C scripts checkout -- player.gd",
      "find scripts -name '*.gd' -delete",
      "find . -type f -exec rm {} +",
      "ls scripts | xargs rm scripts/player.gd",
      "Out-File -FilePath scripts/player.gd -InputObject x",
    ]) {
      assert.equal(commandWrites(command, project), true, command);
    }
  });

  test("refuses a one-line script that writes one", () => {
    const { project } = workspace();
    for (const command of [
      `python -c "open('scripts/player.gd', 'w').write('extends Node')"`,
      `node -e "require('fs').writeFileSync('project.godot', '')"`,
      `bash -c "echo x > scripts/player.gd"`,
      `pwsh -Command "Set-Content scripts/player.gd 'x'"`,
      "python - <<'EOF'\nopen('addons/x/plugin.gd', 'w').write('@tool')\nEOF",
      `perl -e 'open(F, ">scripts/player.gd"); print F "x"'`,
      "bash -lc 'echo x > scripts/player.gd'",
      "powershell -Command Set-Content scripts/player.gd x",
      "cmd /c copy ..\\scratch\\a.gd scripts\\a.gd",
      "bash <<'EOF'\necho x > scripts/player.gd\nEOF",
    ]) {
      assert.equal(commandWrites(command, project), true, command);
    }
  });

  test("lets reading, running and copying out through", () => {
    const { project } = workspace();
    for (const command of [
      "cat scripts/player.gd",
      "grep -rn extends scripts/ | head -5",
      "cp scripts/player.gd ../scratch/player.gd",
      "Copy-Item scripts\\player.gd -Destination ..\\scratch\\player.gd",
      "gd command fs_write_text --path res://scripts/player.gd --text-file ../scratch/player.gd --overwrite true --yes",
      "gd command fs_delete --path res://scripts/player.gd --yes",
      "echo done > ../scratch/log.txt",
      "echo notes > docs.md",
      "rm ../scratch/player.gd",
      "sed -n 1,20p scripts/player.gd",
      "sed 's/a/b/' scripts/player.gd > ../scratch/out.gd",
      "git add scripts/player.gd && git commit -m 'x'",
      "git diff -- scripts/player.gd",
      "python tools/build.py",
      `python -c "print(open('scripts/player.gd').read())"`,
      "godot --headless --path . --script res://tests/run.gd 2>&1 | tail -5",
      "echo 'rm scripts/player.gd'",
      `python -c "print(open('addons/x.txt').read())"`,
      `bash -c "grep -rn remove --include=*.gd ."`,
      'Set-Content notes.md "fix scripts/main.gd"',
      "find . -name '*.tmp' -delete",
      "find scripts -name '*.gd'",
      "cat <<'EOF' > ../scratch/x.gd\nextends Node\nEOF\ncat ../scratch/x.gd",
      "git -C scripts log -- player.gd",
      "cat scripts/player.gd >&2",
    ]) {
      assert.equal(commandWrites(command, project), false, command);
    }
  });

  test("leaves projects without the bridge and files outside a project alone", () => {
    const plain = workspace({ bridge: false });
    const { root } = workspace();

    assert.equal(commandWrites("echo x > scripts/player.gd", plain.project), false);
    assert.equal(commandWrites("echo x > scratch/player.gd", root), false);
    assert.equal(commandWrites("echo x > game/scripts/player.gd", root), true);
  });

  test("does not guess at what it cannot resolve", () => {
    const { project } = workspace();

    assert.equal(commandWrites("cp scripts/player.gd $TMP/player.gd", project), false);
    assert.equal(commandWrites("echo x > $TARGET", project), false);
  });
});

describe("decide", () => {
  test("denies with a fixed reason that names the commands to use instead", () => {
    const { project } = workspace();

    const decision = decide({ tool_name: "Bash", tool_input: { command: "rm scripts/player.gd" }, cwd: project }, {});

    assert.equal(decision?.hookSpecificOutput.permissionDecision, "deny");
    assert.match(decision?.hookSpecificOutput.permissionDecisionReason ?? "", /gd command fs_write_text/u);
    assert.equal((decision?.hookSpecificOutput.permissionDecisionReason ?? "").includes(project), false);
  });

  test("says nothing about other commands, other input, or when the user set the override", () => {
    const { project } = workspace();
    const event = { tool_name: "Bash", tool_input: { command: "rm scripts/player.gd" }, cwd: project };

    assert.equal(decide({ tool_name: "Bash", tool_input: { command: "ls" }, cwd: project }, {}), null);
    assert.equal(decide({ tool_name: "Bash", tool_input: {}, cwd: project }, {}), null);
    assert.equal(decide(null, {}), null);
    assert.equal(decide(event, { GDCLI_ALLOW_DIRECT_WRITES: "1" }), null);
  });
});

describe("the hook as a process", () => {
  test("prints a deny decision for a write and nothing for a read", () => {
    const { project } = workspace();
    const environment = { ...process.env };
    delete environment["GDCLI_ALLOW_DIRECT_WRITES"];
    const run = (command) =>
      spawnSync(process.execPath, [HOOK], { input: JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd: project }), encoding: "utf8", env: environment });

    const denied = run("echo x > scripts/player.gd");
    const allowed = run("cat scripts/player.gd");

    assert.equal(JSON.parse(denied.stdout).hookSpecificOutput.permissionDecision, "deny");
    assert.deepEqual([allowed.status, allowed.stdout], [0, ""]);
  });
});
