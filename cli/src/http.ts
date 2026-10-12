import http from "node:http";

const LOOPBACK = "127.0.0.1";
// Larger than anything the bridge sends; a peer that sends more is not the bridge.
const MAX_RESPONSE_BYTES = 16 * 1024 * 1024;

export interface HttpRequestOptions {
  readonly port: number;
  readonly method: "GET" | "POST";
  readonly path: string;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: string;
  /** Limit for the whole exchange, not just for gaps between bytes. */
  readonly timeoutMs: number;
}

export interface HttpResponse {
  readonly status: number;
  readonly body: string;
}

export type TransportFailure = "refused" | "timeout" | "other";

export class TransportError extends Error {
  readonly kind: TransportFailure;

  constructor(kind: TransportFailure, message: string) {
    super(message);
    this.name = "TransportError";
    this.kind = kind;
  }
}

function kindOf(error: NodeJS.ErrnoException): TransportFailure {
  return error.code === "ECONNREFUSED" ? "refused" : "other";
}

/**
 * One request to the bridge. The host is fixed to loopback: the lock file's
 * host field is never used as a destination (docs/protocol.md section 2).
 */
export function httpRequest(options: HttpRequestOptions): Promise<HttpResponse> {
  return new Promise((resolvePromise, reject) => {
    const headers: Record<string, string> = { ...options.headers };
    if (options.body !== undefined) {
      headers["Content-Length"] = String(Buffer.byteLength(options.body));
    }
    const fail = (error: unknown): void => {
      clearTimeout(deadline);
      const errno = error as NodeJS.ErrnoException;
      reject(error instanceof TransportError ? error : new TransportError(kindOf(errno), errno.message));
    };
    const request = http.request(
      { host: LOOPBACK, port: options.port, method: options.method, path: options.path, headers, agent: false },
      (response) => {
        const chunks: Buffer[] = [];
        let received = 0;
        response.on("data", (chunk: Buffer) => {
          received += chunk.length;
          if (received > MAX_RESPONSE_BYTES) {
            request.destroy(new TransportError("other", "The reply is larger than the bridge would send."));
            return;
          }
          chunks.push(chunk);
        });
        response.on("end", () => {
          clearTimeout(deadline);
          resolvePromise({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") });
        });
        response.on("error", fail);
      },
    );
    // A total deadline: a peer that trickles one byte at a time must not be
    // able to keep gd waiting forever.
    const deadline = setTimeout(() => {
      request.destroy(new TransportError("timeout", "The editor did not answer in time."));
    }, options.timeoutMs);
    request.on("error", fail);
    request.end(options.body);
  });
}
