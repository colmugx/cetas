/**
 * image-attachments.ts — `@path` image attachment resolution for the TUI.
 *
 * An `@path` mention that resolves to a workspace image file is attached
 * inline as a base64 Image block alongside the prompt text; the text mention
 * itself stays in the prompt for provenance. Non-image mentions are left to
 * the read tool, exactly as before.
 *
 * Guardrails, mirroring the CLI-agent consensus (Claude Code / Codex / Crush):
 * one attachment per resolved path, a decoded-size cap (oversized payloads
 * bloat both the request and the session JSONL), and per-problem warnings the
 * submit path renders as system notices. The active-model `image_in` gate is
 * a submit-path concern, not this module's.
 */

export const IMAGE_MENTION_EXTENSIONS = [
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
] as const;

/** Wire form consumed by the MoonBit `images_json` bridge parameter. */
export interface ImageAttachment {
  media_type: string;
  data: string;
}

export interface ImageAttachmentResolution {
  attachments: ImageAttachment[];
  warnings: string[];
  /** Resolved workspace-relative paths, for the echo row's chips. */
  paths: string[];
}

const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

const MIME_BY_EXTENSION: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
};

/** Whether the prompt contains any `@token` that looks like an image path. */
export function hasImageMention(prompt: string): boolean {
  return findImageMentions(prompt).length > 0;
}

/** `@`-tokens whose extension looks like an image (paths still unverified). */
export function findImageMentions(prompt: string): string[] {
  const tokens: string[] = [];
  for (const match of prompt.matchAll(/(?:^|\s)@([^\s@]+)/g)) {
    const token = (match[1] ?? "").replace(/^[("'{]+/, "").replace(/[)"'\]},.:;!?]+$/, "");
    const lower = token.toLowerCase();
    if (IMAGE_MENTION_EXTENSIONS.some((ext) => lower.endsWith(ext))) {
      tokens.push(token);
    }
  }
  return tokens;
}

/**
 * Resolve a mention token against the workspace listing: an exact relative
 * path first, then a unique suffix match (the autocomplete inserts relative
 * paths, but users may type a suffix). `null` means unresolvable.
 */
function resolveWorkspacePath(
  token: string,
  listing: readonly string[] | null,
): string | null {
  if (listing === null || listing.length === 0) return null;
  const lower = token.toLowerCase();
  const exact = listing.find((entry) => entry.toLowerCase() === lower);
  if (exact !== undefined) return exact;
  const suffix = listing.filter((entry) => {
    const l = entry.toLowerCase();
    return l.endsWith("/" + lower) || l === lower;
  });
  if (suffix.length === 1) return suffix[0]!;
  return null;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function readWorkspaceFile(absolutePath: string): Promise<Uint8Array> {
  const bun = (globalThis as { Bun?: { file(path: string): { arrayBuffer(): Promise<ArrayBuffer> } } }).Bun;
  if (bun === undefined) {
    throw new Error("image attachments require the Bun runtime");
  }
  const buffer = await bun.file(absolutePath).arrayBuffer();
  return new Uint8Array(buffer);
}

function formatBytes(size: number): string {
  if (size >= 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(size / 1024))} KB`;
}

/**
 * Scan the prompt for image `@mentions`, verify each against the workspace
 * file listing, read and base64-encode the survivors. Failures are warnings,
 * never exceptions: the prompt still goes out with its text mentions.
 */
export async function resolveImageAttachments(
  prompt: string,
  cwd: string,
  listFiles: () => Promise<readonly string[]>,
): Promise<ImageAttachmentResolution> {
  const warnings: string[] = [];
  const attachments: ImageAttachment[] = [];
  const paths: string[] = [];
  const seen = new Set<string>();
  let listing: readonly string[] | null = null;
  try {
    listing = [...(await listFiles())];
  } catch {
    listing = null;
  }
  for (const token of findImageMentions(prompt)) {
    const resolved = resolveWorkspacePath(token, listing);
    if (resolved === null) {
      warnings.push(`@${token}: no matching workspace image file; not attached`);
      continue;
    }
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    const ext = IMAGE_MENTION_EXTENSIONS.find((e) => resolved.toLowerCase().endsWith(e));
    if (ext === undefined) continue;
    try {
      const bytes = await readWorkspaceFile(`${cwd}/${resolved}`);
      if (bytes.byteLength > MAX_IMAGE_BYTES) {
        warnings.push(
          `@${resolved}: ${formatBytes(bytes.byteLength)} exceeds the 5 MB attachment limit; not attached`,
        );
        continue;
      }
      attachments.push({ media_type: MIME_BY_EXTENSION[ext]!, data: toBase64(bytes) });
      paths.push(resolved);
    } catch {
      warnings.push(`@${resolved}: file read failed; not attached`);
    }
  }
  return { attachments, warnings, paths };
}
