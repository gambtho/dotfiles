import { lstatSync, readlinkSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const home = resolve(homedir());
const physicalHome = realpathSync(home);

/** Only these exact OS aliases are accepted outside the trusted HOME boundary.
 * @param {string} path
 * @param {string} target
 */
export function isStandardAlias(path, target) {
  return ["/tmp", "/var", "/etc"].includes(path) && target === `/private${path}`;
}

/** @param {string} root @param {string} path */
function inside(root, path) {
  return path === root || path.startsWith(`${root}${sep}`);
}

/** Check every managed component, including absent destinations, without writes.
 * @param {string} path
 * @param {boolean} directoriesOnly
 */
export function assertManagedPath(path, directoriesOnly = false) {
  path = resolve(path);
  const boundary = inside(home, path) ? home : inside(physicalHome, path) ? physicalHome : undefined;
  for (let current = path; current !== boundary; current = dirname(current)) {
    let stat;
    try {
      stat = lstatSync(current);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (stat?.isSymbolicLink()) {
      const target = resolve(dirname(current), readlinkSync(current));
      if (boundary || !isStandardAlias(current, target) || realpathSync(current) !== target) {
        throw new Error(`refusing symlink in managed path ${current}`);
      }
      // The alias target and its ancestry are strict, not another trust root.
      assertManagedPath(target, true);
    } else if (stat && directoriesOnly && !stat.isDirectory()) {
      throw new Error(`refusing unsafe managed directory ${current}`);
    }
    if (dirname(current) === current) break;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    for (const path of process.argv.slice(2)) assertManagedPath(path, true);
  } catch (error) {
    console.error(`error: ${error.message}`);
    process.exitCode = 1;
  }
}
