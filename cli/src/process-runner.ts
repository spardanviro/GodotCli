import { spawn, spawnSync } from "node:child_process";
import { join } from "node:path";

import type { ProcessResult, ProcessRunner, RunOptions } from "./context.js";

// Enough for a long import log; output beyond this is dropped, oldest first.
const MAX_CAPTURE_CHARS = 8 * 1024 * 1024;
// After the tree was killed, how long to wait for the pipes to close before
// giving up on them: a stray grandchild can keep a pipe open forever.
const CLOSE_GRACE_MS = 5_000;

/**
 * Stops a process and everything it started. Godot's console wrapper on
 * Windows launches the real engine as a child, so killing only the wrapper
 * would leave the game running.
 */
function killTree(pid: number, platform: NodeJS.Platform): void {
  if (platform === "win32") {
    // Absolute path: a bare name is looked up in the working directory first,
    // and the working directory is usually the project.
    const taskkill = join(process.env["SystemRoot"] ?? "C:\\Windows", "System32", "taskkill.exe");
    spawnSync(taskkill, ["/pid", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
    return;
  }
  try {
    // The child leads its own process group, so this reaches its children too.
    process.kill(-pid, "SIGKILL");
  } catch {
    // Already gone.
  }
}

/** Keeps the tail of a stream without re-copying everything on each chunk. */
function createCapture(): { add(chunk: string): void; text(): string } {
  let chunks: string[] = [];
  let length = 0;
  return {
    add(chunk: string): void {
      chunks.push(chunk);
      length += chunk.length;
      if (length > MAX_CAPTURE_CHARS * 2) {
        const joined = chunks.join("");
        chunks = [joined.slice(joined.length - MAX_CAPTURE_CHARS)];
        length = MAX_CAPTURE_CHARS;
      }
    },
    text(): string {
      const joined = chunks.join("");
      return joined.length > MAX_CAPTURE_CHARS ? joined.slice(joined.length - MAX_CAPTURE_CHARS) : joined;
    },
  };
}

/**
 * Starts processes from an argument array, never through a shell, so no
 * value can be reinterpreted as shell syntax (docs/protocol.md section 1.3).
 * `file` must be an absolute path.
 */
export function createProcessRunner(platform: NodeJS.Platform): ProcessRunner {
  // Children run in their own process group or tree, so they do not receive
  // the signal that interrupts gd; they are stopped explicitly instead.
  const alive = new Set<number>();
  return {
    stopAll(): void {
      for (const pid of alive) {
        killTree(pid, platform);
      }
      alive.clear();
    },

    run(file: string, args: readonly string[], options: RunOptions): Promise<ProcessResult> {
      return new Promise((resolvePromise) => {
        const stdout = createCapture();
        const stderr = createCapture();
        let timedOut = false;
        let settled = false;
        let closeTimer: NodeJS.Timeout | undefined;
        const child = spawn(file, [...args], {
          cwd: options.cwd,
          shell: false,
          windowsHide: true,
          // Its own process group on POSIX, so the whole tree can be signalled.
          detached: platform !== "win32",
          stdio: ["ignore", "pipe", "pipe"],
        });
        const { pid } = child;
        if (pid !== undefined) {
          alive.add(pid);
        }
        const settle = (code: number | null, spawnError?: string): void => {
          if (settled) {
            return;
          }
          settled = true;
          if (pid !== undefined) {
            alive.delete(pid);
          }
          clearTimeout(timer);
          clearTimeout(closeTimer);
          resolvePromise({
            code,
            stdout: stdout.text(),
            stderr: stderr.text(),
            timedOut,
            ...(spawnError === undefined ? {} : { spawnError }),
          });
        };
        const timer = setTimeout(() => {
          timedOut = true;
          if (child.pid !== undefined) {
            killTree(child.pid, platform);
          }
          closeTimer = setTimeout(() => {
            child.stdout.destroy();
            child.stderr.destroy();
            settle(null);
          }, CLOSE_GRACE_MS);
        }, options.timeoutMs);
        child.stdout.setEncoding("utf8").on("data", (chunk: string) => stdout.add(chunk));
        child.stderr.setEncoding("utf8").on("data", (chunk: string) => stderr.add(chunk));
        child.on("error", (error) => settle(null, error.message));
        child.on("close", (code) => settle(code));
      });
    },

    startDetached(file: string, args: readonly string[], cwd: string): number | undefined {
      try {
        const child = spawn(file, [...args], { cwd, shell: false, detached: true, stdio: "ignore", windowsHide: true });
        child.on("error", () => {
          // Reported through the missing pid.
        });
        child.unref();
        return child.pid;
      } catch {
        // spawn throws synchronously for some files, e.g. a batch file on Windows.
        return undefined;
      }
    },
  };
}
