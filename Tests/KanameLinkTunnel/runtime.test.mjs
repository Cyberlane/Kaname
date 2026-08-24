import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

import {
  createRuntimePlan,
  extractCloudflaredBinary,
  installPinnedRuntime,
  loadRuntimeManifest,
  normalizeRuntimeManifest,
  selectRuntimeArtifact,
  verifyPinnedRuntime,
} from "../../Scripts/kaname-link-cloudflared-runtime.mjs";

const TEST_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(TEST_DIRECTORY, "../..");
const MANIFEST_PATH = path.join(
  REPOSITORY_ROOT,
  "Infrastructure",
  "KanameLinkTunnel",
  "cloudflared-runtime.json",
);

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function writeTarOctal(header, offset, length, value) {
  const octal = value.toString(8).padStart(length - 2, "0");
  header.write(`${octal}\0 `, offset, length, "ascii");
}

function createTarGzip(entryName, contents) {
  const content = Buffer.from(contents);
  const header = Buffer.alloc(512);
  header.write(entryName, 0, 100, "utf8");
  writeTarOctal(header, 100, 8, 0o755);
  writeTarOctal(header, 108, 8, 0);
  writeTarOctal(header, 116, 8, 0);
  writeTarOctal(header, 124, 12, content.length);
  writeTarOctal(header, 136, 12, 0);
  header.fill(32, 148, 156);
  header[156] = "0".charCodeAt(0);
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  const checksum = [...header].reduce((total, byte) => total + byte, 0);
  writeTarOctal(header, 148, 8, checksum);
  const padding = Buffer.alloc((512 - (content.length % 512)) % 512);
  return gzipSync(Buffer.concat([header, content, padding, Buffer.alloc(1024)]));
}

async function withTemporaryDirectory(run) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "kaname-link-runtime-test-"));
  try {
    return await run(directory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

test("runtime manifest pins current Cloudflare artifacts and disables automatic updates", async () => {
  const manifest = await loadRuntimeManifest(MANIFEST_PATH);
  assert.equal(manifest.version, "2026.8.2");
  assert.equal(manifest.updatePolicy.automaticUpdates, false);
  assert.equal(manifest.updatePolicy.approvalRequired, true);
  assert.equal(manifest.secretBoundary.persistedByDelivery, false);
  assert.deepEqual(Object.keys(manifest.artifacts).sort(), [
    "darwin-arm64",
    "darwin-x64",
    "linux-arm64",
    "linux-x64",
    "win32-x64",
  ]);
  for (const artifact of Object.values(manifest.artifacts)) {
    assert.match(artifact.sha256, /^[0-9a-f]{64}$/);
  }
});

test("runtime plan selects one exact platform artifact without mutation", async () => {
  const manifest = await loadRuntimeManifest(MANIFEST_PATH);
  await withTemporaryDirectory(async (directory) => {
    const plan = createRuntimePlan({
      manifest,
      destination: path.join(directory, "cloudflared"),
      receiptPath: path.join(directory, "install-receipt.json"),
      platform: "darwin",
      architecture: "arm64",
    });
    assert.equal(plan.artifact.id, "darwin-arm64");
    assert.equal(plan.artifact.fileName, "cloudflared-darwin-arm64.tgz");
    assert.equal(plan.artifact.sha256, manifest.artifacts["darwin-arm64"].sha256);
    assert.equal(plan.automaticUpdates, false);
    assert.equal(plan.tokenPersisted, false);
  });
});

test("installer verifies checksum, writes a non-secret receipt, and verifies binary identity", async () => {
  const manifest = await loadRuntimeManifest(MANIFEST_PATH);
  const binary = Buffer.from("synthetic offline cloudflared binary");
  const testManifest = clone(manifest);
  testManifest.artifacts["linux-x64"].sha256 = sha256(binary);
  const fetchImpl = async () =>
    new Response(binary, {
      status: 200,
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(binary.length),
      },
    });

  await withTemporaryDirectory(async (directory) => {
    const binaryPath = path.join(directory, "cloudflared");
    const receiptPath = path.join(directory, "install-receipt.json");
    const result = await installPinnedRuntime({
      manifest: testManifest,
      destination: binaryPath,
      receiptPath,
      confirmation: manifest.version,
      platform: "linux",
      architecture: "x64",
      fetchImpl,
      clock: () => Date.parse("2026-08-24T12:00:00.000Z"),
    });
    assert.equal(result.ok, true);
    assert.deepEqual(await readFile(binaryPath), binary);
    const receiptText = await readFile(receiptPath, "utf8");
    assert.equal(receiptText.includes("eyJhIjoi"), false);
    assert.equal(receiptText.includes("TUNNEL_TOKEN"), false);
    assert.equal((await stat(receiptPath)).mode & 0o077, 0);
    const verification = await verifyPinnedRuntime({
      manifest: testManifest,
      binaryPath,
      receiptPath,
    });
    assert.equal(verification.ok, true);
    assert.equal(verification.binarySHA256, sha256(binary));
  });
});

test("installer fails closed on checksum mismatch without creating runtime files", async () => {
  const manifest = await loadRuntimeManifest(MANIFEST_PATH);
  await withTemporaryDirectory(async (directory) => {
    const binaryPath = path.join(directory, "cloudflared");
    const receiptPath = path.join(directory, "install-receipt.json");
    await assert.rejects(
      installPinnedRuntime({
        manifest,
        destination: binaryPath,
        receiptPath,
        confirmation: manifest.version,
        platform: "linux",
        architecture: "x64",
        fetchImpl: async () => new Response("wrong artifact", { status: 200 }),
      }),
      { code: "runtime_checksum_mismatch" },
    );
    await assert.rejects(stat(binaryPath), { code: "ENOENT" });
    await assert.rejects(stat(receiptPath), { code: "ENOENT" });
  });
});

test("Darwin archive extraction accepts one binary and rejects path traversal", async () => {
  const manifest = await loadRuntimeManifest(MANIFEST_PATH);
  const artifact = selectRuntimeArtifact(manifest, {
    platform: "darwin",
    architecture: "arm64",
  });
  const expected = Buffer.from("synthetic macOS cloudflared");
  assert.deepEqual(extractCloudflaredBinary(createTarGzip("cloudflared", expected), artifact), expected);
  assert.throws(
    () => extractCloudflaredBinary(createTarGzip("../cloudflared", expected), artifact),
    { code: "invalid_runtime_artifact" },
  );
});

test("runtime manifest rejects automatic updates and unapproved supervisor arguments", async () => {
  const manifest = await loadRuntimeManifest(MANIFEST_PATH);
  const automatic = clone(manifest);
  automatic.updatePolicy.automaticUpdates = true;
  assert.throws(() => normalizeRuntimeManifest(automatic), {
    code: "invalid_runtime_manifest",
  });
  const tokenArgument = clone(manifest);
  tokenArgument.supervisor.arguments.push("--token");
  assert.throws(() => normalizeRuntimeManifest(tokenArgument), {
    code: "invalid_runtime_manifest",
  });
});
