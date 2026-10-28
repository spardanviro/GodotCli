# Security

gdcli lets programs drive a Godot editor. Its rules about what may run inside the editor, and what needs a person's
approval, are part of the product: a way around them is a vulnerability, and so is anything that lets another user
or another program on the machine reach the bridge.

## Reporting a vulnerability

Please report it privately, not in a public issue:

- **GitHub**: [report a vulnerability](https://github.com/spardanviro/GodotCli/security/advisories/new)
  (the repository's Security tab, "Report a vulnerability").

Say which part it is in (the bridge in `addons/gdcli`, the `gd` command line, the MCP server, the Claude plugin's
hooks), the versions of gdcli and Godot, and the steps that show it. You will get an answer within a week. Fixes are
released as a new version and described in a published security advisory, crediting you unless you would rather
not be named.

## Supported versions

Fixes go into the latest release. Update the command line (`npm install -g @spardanviro/gdcli`), the bridge in each
project (`gd bridge install --force`) and the Claude plugin (`claude plugin update godot@gdcli`) together; `gd`
warns when the bridge in a project differs from its own.

## What counts

The security model is described in [docs/protocol.md](docs/protocol.md), section 4 (in Chinese). In short, these
are vulnerabilities:

- Code running inside the editor process through the bridge without a person's approval, outside `full` mode:
  `@tool` scripts, files under `addons/`, autoloads and other settings that decide which code loads, C# files,
  import scripts, scenes or resources that use files outside the project, `eval`.
- Reading or writing files outside the project through the bridge, or inside `.git` or the bridge's own folder.
- Reaching the bridge without its token, from another machine, or as another user.
- A change in `readonly` mode, or a destructive change in `standard` mode without the caller's confirmation.
- The Claude plugin's hooks letting an ordinary file or shell tool write a guarded project file in a way they are
  documented to catch.

These are known limits, not vulnerabilities: the game's own code runs with the user's rights when the game is run;
code already in the project runs when the editor loads it; an agent that writes files without going through the
bridge is held back only by the plugin's hooks and the client's own sandbox, as documented in
[plugin/README.md](plugin/README.md).
