import type { Envelope } from "./envelope.js";

export interface Io {
  readonly stdout: (text: string) => void;
  readonly stderr: (text: string) => void;
  readonly env: Readonly<Record<string, string | undefined>>;
  /** Everything on standard input, read to its end. */
  readonly readStdin: () => string;
  /** Standard input line by line as it arrives (gd mcp); absent where it cannot be read so. */
  readonly readLines?: () => AsyncIterable<string>;
}

export interface ProcessResult {
  /** Exit status; null when the process was killed or never started. */
  readonly code: number | null;
  readonly stdout: string;
  readonly stderr: string;
  readonly timedOut: boolean;
  /** Set when the process could not be started at all. */
  readonly spawnError?: string;
}

export interface RunOptions {
  readonly cwd?: string;
  readonly timeoutMs: number;
}

export interface ProcessRunner {
  run(file: string, args: readonly string[], options: RunOptions): Promise<ProcessResult>;
  /** Starts a process that outlives the CLI. Returns its pid, if it started. */
  startDetached(file: string, args: readonly string[], cwd: string): number | undefined;
  /** Stops every process started with run() that is still alive. */
  stopAll(): void;
  /** Whether a process with this id exists. */
  isAlive(pid: number): boolean;
}

/** Everything a command needs from the outside world; replaced in tests. */
export interface Context {
  readonly io: Io;
  readonly cwd: string;
  readonly platform: NodeJS.Platform;
  readonly homeDir: string;
  /** Process id of this gd. */
  readonly pid: number;
  /** Folder holding the bridge addon shipped with this package. */
  readonly addonDir: string;
  readonly processes: ProcessRunner;
  readonly readVersion: () => string;
  /** The program and arguments that start this gd (node and its script), for configuration files that start it again. */
  readonly launcher?: readonly string[];
  /** Work to do before gd exits on SIGINT or SIGTERM (a few seconds at most). */
  /** Registers what to do when gd is interrupted; the returned function unregisters it. */
  readonly onInterrupt?: (cleanup: () => Promise<void>) => () => void;
}

export type OutputFormat = "human" | "json";

/** Options accepted by every command. */
export interface GlobalOptions {
  readonly format: OutputFormat;
  readonly project?: string;
  readonly instance?: string;
  readonly godot?: string;
  readonly timeoutMs?: number;
  readonly yes: boolean;
  readonly dryRun: boolean;
}

export interface CommandResult {
  readonly envelope: Envelope;
  /** Text for people; used only when the envelope reports success. */
  readonly human: string;
  /** The command wrote its own output (gd mcp's protocol stream): nothing more is printed. */
  readonly printed?: boolean;
}

export type CommandHandler = (
  context: Context,
  globals: GlobalOptions,
  args: readonly string[],
) => Promise<CommandResult>;
