// The pinned actor's Playwright browser is a separate session on macOS. Record every detached
// spawn before returning it to Playwright so supervisor death cannot hide an owned browser group.
// Launch intents left unresolved by interruption fail finalization; they never authorize a guess.
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const registry = process.env.NTP_FIXTURE_OWNERSHIP_DIR;
if (!registry) throw new Error("actor detached-process ownership registry is required");
fs.mkdirSync(registry, { recursive: true, mode: 0o700 });
fs.chmodSync(registry, 0o700);
const originalSpawn = childProcess.spawn;
const originalSpawnSync = childProcess.spawnSync;
function receipt(file, entry) {
  const temporary = file + ".tmp";
  fs.writeFileSync(temporary, JSON.stringify(entry) + "\n", { mode: 0o600 });
  fs.chmodSync(temporary, 0o600);
  fs.renameSync(temporary, file);
}
childProcess.spawn = function(command, args, options) {
  const opts = Array.isArray(args) ? (options || {}) : (args || {});
  if (!opts.detached) return originalSpawn.apply(this, arguments);
  const file = path.join(registry, crypto.randomUUID() + ".json");
  receipt(file, { registered: false, supervisor: process.pid });
  let child;
  try {
    child = originalSpawn.apply(this, arguments);
  } catch (error) {
    receipt(file, { registered: true, spawn_failed: true, exited: true });
    throw error;
  }
  if (!child.pid) {
    child.once("error", () => receipt(file, { registered: true, spawn_failed: true, exited: true }));
    return child;
  }
  const probe = originalSpawnSync("/bin/ps", ["-o", "lstart=", "-p", String(child.pid)], { encoding: "utf8" });
  const birth = (probe.stdout || "").trim();
  receipt(file, { registered: true, pid: child.pid, birth, members: { [String(child.pid)]: birth },
    exited: false, supervisor: process.pid });
  return child;
};
require("node:module").syncBuiltinESMExports();
