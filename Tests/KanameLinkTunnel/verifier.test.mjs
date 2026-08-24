import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const TEST_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(TEST_DIRECTORY, "../..");
const VERIFIER_PATH = path.join(REPOSITORY_ROOT, "Scripts", "verify-kaname-link-tunnel.sh");

test("public verifier negatively probes loopback-only and non-exact paths", async () => {
  const verifier = await readFile(VERIFIER_PATH, "utf8");
  assert.match(verifier, /probe_denied_public_path "\/health"/);
  assert.match(verifier, /probe_denied_public_path "\/v1\/enroll\/extra"/);
  assert.match(verifier, /probe_denied_public_path "\/__kaname_link_unauthenticated_probe__"/);
  assert.match(verifier, /401\|403\|404/);
  assert.doesNotMatch(verifier, /401\|403\|404\|426/);
});
