import { randomUUID } from "node:crypto";
import { lstat, link, mkdir, open, rm } from "node:fs/promises";
import { join } from "node:path";

const MINIMAL_SETTINGS = '{"providers":{}}\n';

function isErrno(error: unknown, code: string): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === code;
}

/**
 * First-run bootstrap for the JS terminal host. Publish a *complete* JSON file
 * without replacing any existing directory entry (including dangling links).
 *
 * A direct `open(path, "wx")` would expose a zero-byte settings.json while it
 * was being written, and `rename()` can replace another process's settings on
 * Windows. Linking an fsynced same-directory staging file is atomic and fails
 * with EEXIST if another process won the race. Existing invalid settings are
 * deliberately not repaired or overwritten: the normal settings loader must
 * report those to the user.
 *
 * Returns true only for the process that published the new file.
 */
export async function bootstrapSettings(home: string): Promise<boolean> {
  const dir = join(home, ".cetas");
  const path = join(dir, "settings.json");
  try {
    await lstat(path);
    return false;
  } catch (error: unknown) {
    if (!isErrno(error, "ENOENT")) throw error;
  }

  await mkdir(dir, { recursive: true, mode: 0o700 });
  const staging = join(dir, `.settings-bootstrap-${process.pid}-${randomUUID()}.tmp`);
  const file = await open(staging, "wx", 0o600);
  try {
    try {
      await file.writeFile(MINIMAL_SETTINGS, "utf8");
      await file.sync();
    } finally {
      await file.close();
    }
    try {
      await link(staging, path);
      return true;
    } catch (error: unknown) {
      if (isErrno(error, "EEXIST")) return false;
      throw error;
    }
  } finally {
    await rm(staging, { force: true });
  }
}
