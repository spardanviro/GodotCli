/** One argument of a bridge command: the JSON Schema subset of protocol.md section 7. */
export interface Parameter {
  readonly type?: string;
  readonly description?: string;
  readonly default?: unknown;
  readonly enum?: readonly unknown[];
  readonly items?: unknown;
  readonly minimum?: number;
  readonly maximum?: number;
}

/** A bridge command as GET /v1/commands lists it. */
export interface Descriptor {
  readonly name: string;
  readonly group?: string;
  readonly summary?: string;
  /** read, write, destructive or exec. */
  readonly risk?: string;
  readonly undoable?: boolean;
  readonly requires?: readonly string[];
  readonly returns?: string;
  /** The protocol version that introduced it. */
  readonly since?: number;
  /** Added by the project (gdcli_commands/), not built into the bridge. */
  readonly custom?: boolean;
  readonly params?: {
    readonly type?: string;
    readonly properties?: Readonly<Record<string, Parameter>>;
    readonly required?: readonly string[];
  };
}

/** Whether a value read from the bridge has the shape of a descriptor. */
export function isDescriptor(value: unknown): value is Descriptor {
  return typeof value === "object" && value !== null && typeof (value as { name?: unknown }).name === "string";
}
