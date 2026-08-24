#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import {
  chmod,
  link,
  lstat,
  readFile,
  unlink,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { gunzipSync } from "node:zlib";

import {
  canonicalJSON,
  parseCommandOptions,
  rejectUnexpectedKeys,
  validateExternalFilePath,
} from "./kaname-link-delivery-common.mjs";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REPOSITORY_ROOT = path.resolve(path.dirname(SCRIPT_PATH), "..");
const DEFAULT_MANIFEST_PATH = path.join(
  REPOSITORY_ROOT,
  "Infrastructure",
  "KanameLinkTunnel",
  "cloudflared-runtime.json",
);
const MAX_ARTIFACT_BYTES = 150 * 1024 * 1024;
const MAX_BINARY_BYTES = 200 * 1024 * 1024;
const ALLOWED_DOWNLOAD_HOSTS = new Set([
  "github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
]);
const SUPPORTED_FORMATS = new Set(["raw", "tar.gz"]);
const EXPECTED_SUPERVISOR_ARGUMENTS = [
  "tunnel",
  "--no-autoupdate",
  "--loglevel",
  "info",
  "--metrics",
  "127.0.0.1:43111",
  "run",
];
const RUNTIME_COMMAND_OPTIONS = {
  commands: ["plan", "install", "verify"],
  defaults: {
    manifestPath: DEFAULT_MANIFEST_PATH,
    destination: null,
    receiptPath: null,
    confirmation: null,
  },
  optionProperties: {
    "--manifest": "manifestPath",
    "--destination": "destination",
    "--receipt": "receiptPath",
    "--confirm": "confirmation",
  },
};

export class RuntimeDeliveryError extends Error {
  constructor(code, message, options = {}) {
    super(message, options);
    this.name = "RuntimeDeliveryError";
    this.code = code;
  }
}

function fail(code, message, options) {
  throw new RuntimeDeliveryError(code, message, options);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireObject(value, label) {
  if (!isPlainObject(value)) fail("invalid_runtime_manifest", `${label} must be an object`);
  return value;
}

function requireExactKeys(value, allowed, label) {
  rejectUnexpectedKeys(value, allowed, label, (message) =>
    fail("invalid_runtime_manifest", message),
  );
}

function requireString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    fail("invalid_runtime_manifest", `${label} must be a non-empty string`);
  }
  return value;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

export function validateManagedPath(candidate, repositoryRoot = REPOSITORY_ROOT) {
  return validateExternalFilePath(candidate, repositoryRoot, "runtime path", (message) =>
    fail("invalid_runtime_path", message),
  );
}

export function normalizeRuntimeManifest(raw) {
  const manifest = requireObject(raw, "cloudflared runtime manifest");
  requireExactKeys(
    manifest,
    [
      "schemaVersion",
      "component",
      "version",
      "releasePage",
      "downloadBaseURL",
      "tokenFileDocumentation",
      "updatePolicy",
      "secretBoundary",
      "supervisor",
      "artifacts",
    ],
    "cloudflared runtime manifest",
  );
  if (manifest.schemaVersion !== 1 || manifest.component !== "cloudflared") {
    fail("invalid_runtime_manifest", "runtime manifest identity is unsupported");
  }
  const version = requireString(manifest.version, "version");
  if (!/^20[2-9][0-9]\.[1-9][0-9]?\.[0-9]+$/.test(version)) {
    fail("invalid_runtime_manifest", "version must be a pinned cloudflared calendar version");
  }
  const releasePage = requireString(manifest.releasePage, "releasePage");
  const downloadBaseURL = requireString(manifest.downloadBaseURL, "downloadBaseURL");
  if (
    releasePage !== `https://github.com/cloudflare/cloudflared/releases/tag/${version}` ||
    downloadBaseURL !==
      `https://github.com/cloudflare/cloudflared/releases/download/${version}/`
  ) {
    fail("invalid_runtime_manifest", "release URLs must be exact pinned Cloudflare GitHub URLs");
  }
  if (
    manifest.tokenFileDocumentation !==
    "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/#token-file"
  ) {
    fail("invalid_runtime_manifest", "token-file documentation URL is unexpected");
  }

  const updatePolicy = requireObject(manifest.updatePolicy, "updatePolicy");
  requireExactKeys(
    updatePolicy,
    ["automaticUpdates", "approvalRequired", "procedure"],
    "updatePolicy",
  );
  if (
    updatePolicy.automaticUpdates !== false ||
    updatePolicy.approvalRequired !== true ||
    typeof updatePolicy.procedure !== "string" ||
    updatePolicy.procedure.length < 40
  ) {
    fail("invalid_runtime_manifest", "runtime updates must be pinned and explicitly approved");
  }

  const secretBoundary = requireObject(manifest.secretBoundary, "secretBoundary");
  requireExactKeys(
    secretBoundary,
    ["source", "delivery", "persistedByDelivery", "forbidden"],
    "secretBoundary",
  );
  if (
    secretBoundary.persistedByDelivery !== false ||
    !Array.isArray(secretBoundary.forbidden) ||
    !secretBoundary.forbidden.includes("command-line arguments") ||
    !secretBoundary.forbidden.includes("configuration files") ||
    !secretBoundary.forbidden.includes("install receipts") ||
    !secretBoundary.forbidden.includes("logs")
  ) {
    fail("invalid_runtime_manifest", "secret boundary does not forbid token persistence/exposure");
  }

  const supervisor = requireObject(manifest.supervisor, "supervisor");
  requireExactKeys(
    supervisor,
    ["arguments", "maximumConsecutiveRestarts", "restartDelaysMilliseconds"],
    "supervisor",
  );
  if (canonicalJSON(supervisor.arguments) !== canonicalJSON(EXPECTED_SUPERVISOR_ARGUMENTS)) {
    fail("invalid_runtime_manifest", "cloudflared supervisor arguments are not the approved set");
  }
  if (
    !Number.isSafeInteger(supervisor.maximumConsecutiveRestarts) ||
    supervisor.maximumConsecutiveRestarts < 0 ||
    supervisor.maximumConsecutiveRestarts > 20 ||
    !Array.isArray(supervisor.restartDelaysMilliseconds) ||
    supervisor.restartDelaysMilliseconds.length === 0 ||
    supervisor.restartDelaysMilliseconds.some(
      (delay) => !Number.isSafeInteger(delay) || delay < 100 || delay > 60_000,
    )
  ) {
    fail("invalid_runtime_manifest", "cloudflared restart policy is invalid");
  }

  const artifacts = requireObject(manifest.artifacts, "artifacts");
  if (Object.keys(artifacts).length === 0) {
    fail("invalid_runtime_manifest", "runtime manifest must contain pinned artifacts");
  }
  const normalizedArtifacts = {};
  for (const [artifactId, artifactValue] of Object.entries(artifacts)) {
    const artifact = requireObject(artifactValue, `artifacts.${artifactId}`);
    requireExactKeys(
      artifact,
      ["platform", "architecture", "fileName", "format", "sha256"],
      `artifacts.${artifactId}`,
    );
    const platform = requireString(artifact.platform, `${artifactId}.platform`);
    const architecture = requireString(artifact.architecture, `${artifactId}.architecture`);
    const fileName = requireString(artifact.fileName, `${artifactId}.fileName`);
    const format = requireString(artifact.format, `${artifactId}.format`);
    const checksum = requireString(artifact.sha256, `${artifactId}.sha256`).toLowerCase();
    if (
      artifactId !== `${platform}-${architecture}` ||
      !new Set(["darwin", "linux", "win32"]).has(platform) ||
      !new Set(["arm64", "x64"]).has(architecture) ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]+$/.test(fileName) ||
      !SUPPORTED_FORMATS.has(format) ||
      !/^[0-9a-f]{64}$/.test(checksum)
    ) {
      fail("invalid_runtime_manifest", `artifact ${artifactId} is invalid`);
    }
    if ((platform === "darwin") !== (format === "tar.gz")) {
      fail("invalid_runtime_manifest", `artifact ${artifactId} has an unexpected format`);
    }
    normalizedArtifacts[artifactId] = {
      platform,
      architecture,
      fileName,
      format,
      sha256: checksum,
    };
  }

  return {
    schemaVersion: 1,
    component: "cloudflared",
    version,
    releasePage,
    downloadBaseURL,
    tokenFileDocumentation: manifest.tokenFileDocumentation,
    updatePolicy: clone(updatePolicy),
    secretBoundary: clone(secretBoundary),
    supervisor: clone(supervisor),
    artifacts: normalizedArtifacts,
  };
}

export async function loadRuntimeManifest(filePath = DEFAULT_MANIFEST_PATH) {
  const resolved = path.resolve(filePath);
  try {
    return normalizeRuntimeManifest(JSON.parse(await readFile(resolved, "utf8")));
  } catch (error) {
    if (error instanceof RuntimeDeliveryError) throw error;
    fail("invalid_runtime_manifest", `unable to load runtime manifest at ${resolved}`, {
      cause: error,
    });
  }
}

export function runtimeManifestDigest(manifest) {
  return sha256(canonicalJSON(normalizeRuntimeManifest(manifest)));
}

export function selectRuntimeArtifact(
  manifestInput,
  { platform = process.platform, architecture = process.arch } = {},
) {
  const manifest = normalizeRuntimeManifest(manifestInput);
  const artifactId = `${platform}-${architecture}`;
  const artifact = manifest.artifacts[artifactId];
  if (!artifact) {
    fail(
      "unsupported_runtime_platform",
      `cloudflared ${manifest.version} has no approved artifact for ${artifactId}`,
    );
  }
  return {
    id: artifactId,
    ...clone(artifact),
    downloadURL: `${manifest.downloadBaseURL}${artifact.fileName}`,
    installedFileName: platform === "win32" ? "cloudflared.exe" : "cloudflared",
  };
}

export function createRuntimePlan({
  manifest: manifestInput,
  destination,
  receiptPath,
  platform = process.platform,
  architecture = process.arch,
  repositoryRoot = REPOSITORY_ROOT,
}) {
  const manifest = normalizeRuntimeManifest(manifestInput);
  const binaryPath = validateManagedPath(destination, repositoryRoot);
  const resolvedReceiptPath = validateManagedPath(receiptPath, repositoryRoot);
  if (binaryPath === resolvedReceiptPath) {
    fail("invalid_runtime_path", "binary and install receipt paths must be different");
  }
  const artifact = selectRuntimeArtifact(manifest, { platform, architecture });
  return {
    ok: true,
    operation: "plan",
    version: manifest.version,
    manifestDigest: runtimeManifestDigest(manifest),
    artifact,
    destination: binaryPath,
    receiptPath: resolvedReceiptPath,
    automaticUpdates: false,
    tokenPersisted: false,
  };
}

function readTarString(bytes, offset, length) {
  const end = bytes.indexOf(0, offset);
  const boundedEnd = end === -1 || end >= offset + length ? offset + length : end;
  return bytes.subarray(offset, boundedEnd).toString("utf8").trim();
}

function readTarOctal(bytes, offset, length, label) {
  const value = readTarString(bytes, offset, length).replace(/^0+/, "") || "0";
  if (!/^[0-7]+$/.test(value)) fail("invalid_runtime_artifact", `${label} is not octal`);
  const parsed = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    fail("invalid_runtime_artifact", `${label} is outside the supported range`);
  }
  return parsed;
}

function assertTarChecksum(header) {
  const expected = readTarOctal(header, 148, 8, "tar checksum");
  let actual = 0;
  for (let index = 0; index < header.length; index += 1) {
    actual += index >= 148 && index < 156 ? 32 : header[index];
  }
  if (actual !== expected) fail("invalid_runtime_artifact", "tar header checksum mismatch");
}

export function extractCloudflaredBinary(artifactBytes, artifact) {
  const bytes = Buffer.from(artifactBytes);
  if (bytes.length === 0 || bytes.length > MAX_ARTIFACT_BYTES) {
    fail("invalid_runtime_artifact", "cloudflared artifact size is invalid");
  }
  if (artifact.format === "raw") return bytes;
  if (artifact.format !== "tar.gz") {
    fail("invalid_runtime_artifact", `unsupported cloudflared artifact format ${artifact.format}`);
  }

  let archive;
  try {
    archive = gunzipSync(bytes, { maxOutputLength: MAX_BINARY_BYTES + 1024 * 1024 });
  } catch (error) {
    fail("invalid_runtime_artifact", "cloudflared gzip archive is invalid or too large", {
      cause: error,
    });
  }
  let offset = 0;
  let binary = null;
  while (offset + 512 <= archive.length) {
    const header = archive.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    assertTarChecksum(header);
    const name = readTarString(header, 0, 100);
    const prefix = readTarString(header, 345, 155);
    const entryPath = prefix ? `${prefix}/${name}` : name;
    const normalizedPath = path.posix.normalize(entryPath);
    if (
      entryPath.length === 0 ||
      normalizedPath.startsWith("/") ||
      normalizedPath === ".." ||
      normalizedPath.startsWith("../")
    ) {
      fail("invalid_runtime_artifact", "cloudflared archive contains an unsafe path");
    }
    const size = readTarOctal(header, 124, 12, "tar entry size");
    const type = String.fromCharCode(header[156] || 48);
    const contentStart = offset + 512;
    const contentEnd = contentStart + size;
    if (contentEnd > archive.length) {
      fail("invalid_runtime_artifact", "cloudflared archive entry is truncated");
    }
    if (type === "0") {
      if (path.posix.basename(normalizedPath) !== "cloudflared" || binary !== null) {
        fail(
          "invalid_runtime_artifact",
          "cloudflared archive must contain exactly one regular cloudflared binary",
        );
      }
      if (size === 0 || size > MAX_BINARY_BYTES) {
        fail("invalid_runtime_artifact", "cloudflared binary size is invalid");
      }
      binary = Buffer.from(archive.subarray(contentStart, contentEnd));
    } else if (!new Set(["5", "x", "g"]).has(type)) {
      fail("invalid_runtime_artifact", `cloudflared archive contains unsupported entry type ${type}`);
    }
    offset = contentStart + Math.ceil(size / 512) * 512;
  }
  if (binary === null) {
    fail("invalid_runtime_artifact", "cloudflared archive does not contain its binary");
  }
  return binary;
}

function assertPinnedDownloadURL(url, manifest) {
  const parsed = new URL(url);
  if (
    parsed.protocol !== "https:" ||
    parsed.username !== "" ||
    parsed.password !== "" ||
    !ALLOWED_DOWNLOAD_HOSTS.has(parsed.hostname) ||
    (parsed.hostname === "github.com" && !parsed.href.startsWith(manifest.downloadBaseURL))
  ) {
    fail("unsafe_runtime_download", "cloudflared download escaped the pinned HTTPS release hosts");
  }
  return parsed;
}

export async function fetchPinnedRuntimeArtifact({
  manifest: manifestInput,
  artifact,
  fetchImpl = globalThis.fetch,
}) {
  const manifest = normalizeRuntimeManifest(manifestInput);
  if (typeof fetchImpl !== "function") fail("invalid_runtime", "Fetch is unavailable");
  let url = new URL(artifact.downloadURL);
  for (let redirectCount = 0; redirectCount <= 5; redirectCount += 1) {
    assertPinnedDownloadURL(url, manifest);
    let response;
    try {
      response = await fetchImpl(url, {
        method: "GET",
        headers: { Accept: "application/octet-stream" },
        redirect: "manual",
      });
    } catch (error) {
      fail("runtime_download_failed", "cloudflared artifact download failed", { cause: error });
    }
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      if (!location || redirectCount === 5) {
        fail("runtime_download_failed", "cloudflared artifact redirect was invalid");
      }
      url = new URL(location, url);
      continue;
    }
    if (!response.ok) {
      fail("runtime_download_failed", `cloudflared artifact download returned HTTP ${response.status}`);
    }
    const declaredLength = Number(response.headers.get("content-length"));
    if (Number.isFinite(declaredLength) && declaredLength > MAX_ARTIFACT_BYTES) {
      fail("runtime_download_failed", "cloudflared artifact exceeds the size limit");
    }
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length === 0 || bytes.length > MAX_ARTIFACT_BYTES) {
      fail("runtime_download_failed", "cloudflared artifact body has an invalid size");
    }
    return bytes;
  }
  fail("runtime_download_failed", "cloudflared artifact exceeded the redirect limit");
}

async function requireRealParent(filePath) {
  const parent = path.dirname(filePath);
  let metadata;
  try {
    metadata = await lstat(parent);
  } catch (error) {
    fail("invalid_runtime_path", `runtime parent directory does not exist: ${parent}`, {
      cause: error,
    });
  }
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    fail("invalid_runtime_path", "runtime parent must be a real directory, not a symlink");
  }
}

async function assertAbsent(filePath) {
  try {
    await lstat(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  fail("runtime_collision", `refusing to replace existing path ${filePath}`);
}

async function writeExclusive(filePath, bytes, mode) {
  await requireRealParent(filePath);
  await assertAbsent(filePath);
  const temporary = path.join(
    path.dirname(filePath),
    `.${path.basename(filePath)}.${randomUUID()}.tmp`,
  );
  try {
    await writeFile(temporary, bytes, { flag: "wx", mode });
    await link(temporary, filePath);
    await chmod(filePath, mode);
  } catch (error) {
    fail("runtime_write_failed", `unable to create ${filePath}`, { cause: error });
  } finally {
    try {
      await unlink(temporary);
    } catch {
      // The temporary file may not have been created or has already been removed.
    }
  }
}

async function readRegularFile(filePath, label) {
  let metadata;
  try {
    metadata = await lstat(filePath);
  } catch (error) {
    fail("runtime_missing", `${label} is missing at ${filePath}`, { cause: error });
  }
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    fail("invalid_runtime_path", `${label} must be a regular file, not a symlink`);
  }
  return { metadata, bytes: await readFile(filePath) };
}

export async function installPinnedRuntime({
  manifest: manifestInput,
  destination,
  receiptPath,
  confirmation,
  platform = process.platform,
  architecture = process.arch,
  repositoryRoot = REPOSITORY_ROOT,
  fetchImpl = globalThis.fetch,
  clock = Date.now,
}) {
  const manifest = normalizeRuntimeManifest(manifestInput);
  if (confirmation !== manifest.version) {
    fail("runtime_confirmation_required", `install requires --confirm ${manifest.version}`);
  }
  const plan = createRuntimePlan({
    manifest,
    destination,
    receiptPath,
    platform,
    architecture,
    repositoryRoot,
  });
  await assertAbsent(plan.destination);
  await assertAbsent(plan.receiptPath);
  const artifactBytes = await fetchPinnedRuntimeArtifact({
    manifest,
    artifact: plan.artifact,
    fetchImpl,
  });
  const actualArtifactHash = sha256(artifactBytes);
  if (actualArtifactHash !== plan.artifact.sha256) {
    fail("runtime_checksum_mismatch", "cloudflared artifact SHA-256 does not match the manifest");
  }
  const binary = extractCloudflaredBinary(artifactBytes, plan.artifact);
  const binaryHash = sha256(binary);
  const receipt = {
    schemaVersion: 1,
    component: "cloudflared",
    version: manifest.version,
    manifestDigest: plan.manifestDigest,
    artifactId: plan.artifact.id,
    artifactFileName: plan.artifact.fileName,
    artifactSHA256: plan.artifact.sha256,
    binaryPath: plan.destination,
    binarySHA256: binaryHash,
    installedAt: new Date(clock()).toISOString(),
    tokenPersisted: false,
  };

  await writeExclusive(plan.destination, binary, 0o755);
  try {
    await writeExclusive(
      plan.receiptPath,
      Buffer.from(`${JSON.stringify(receipt, null, 2)}\n`, "utf8"),
      0o600,
    );
  } catch (error) {
    try {
      await unlink(plan.destination);
    } catch {
      // Retain the original receipt error; a later plan will detect a leftover binary.
    }
    throw error;
  }
  return { ok: true, operation: "install", ...receipt };
}

export async function verifyPinnedRuntime({
  manifest: manifestInput,
  binaryPath,
  receiptPath,
  repositoryRoot = REPOSITORY_ROOT,
}) {
  const manifest = normalizeRuntimeManifest(manifestInput);
  const resolvedBinaryPath = validateManagedPath(binaryPath, repositoryRoot);
  const resolvedReceiptPath = validateManagedPath(receiptPath, repositoryRoot);
  const [{ metadata, bytes }, receiptFile] = await Promise.all([
    readRegularFile(resolvedBinaryPath, "cloudflared binary"),
    readRegularFile(resolvedReceiptPath, "cloudflared install receipt"),
  ]);
  let receipt;
  try {
    receipt = JSON.parse(receiptFile.bytes.toString("utf8"));
  } catch (error) {
    fail("invalid_runtime_receipt", "cloudflared install receipt is not valid JSON", {
      cause: error,
    });
  }
  const artifact = selectRuntimeArtifact(manifest, {
    platform: receipt?.artifactId?.split("-")[0],
    architecture: receipt?.artifactId?.split("-").slice(1).join("-"),
  });
  if (
    receipt.schemaVersion !== 1 ||
    receipt.component !== "cloudflared" ||
    receipt.version !== manifest.version ||
    receipt.manifestDigest !== runtimeManifestDigest(manifest) ||
    receipt.artifactId !== artifact.id ||
    receipt.artifactFileName !== artifact.fileName ||
    receipt.artifactSHA256 !== artifact.sha256 ||
    receipt.binaryPath !== resolvedBinaryPath ||
    receipt.binarySHA256 !== sha256(bytes) ||
    receipt.tokenPersisted !== false
  ) {
    fail("runtime_receipt_mismatch", "cloudflared binary or receipt does not match the pinned manifest");
  }
  if (process.platform !== "win32" && (metadata.mode & 0o111) === 0) {
    fail("runtime_permissions_invalid", "cloudflared binary is not executable");
  }
  return {
    ok: true,
    operation: "verify",
    version: manifest.version,
    artifactId: artifact.id,
    binaryPath: resolvedBinaryPath,
    binarySHA256: receipt.binarySHA256,
    tokenPersisted: false,
  };
}

function usage() {
  return `Usage:
  node Scripts/kaname-link-cloudflared-runtime.mjs plan --destination ABSOLUTE_PATH --receipt ABSOLUTE_PATH [--manifest PATH]
  node Scripts/kaname-link-cloudflared-runtime.mjs install --destination ABSOLUTE_PATH --receipt ABSOLUTE_PATH --confirm VERSION [--manifest PATH]
  node Scripts/kaname-link-cloudflared-runtime.mjs verify --destination ABSOLUTE_PATH --receipt ABSOLUTE_PATH [--manifest PATH]

The install command downloads only the manifest-pinned Cloudflare GitHub asset, verifies its exact
SHA-256, and refuses to replace any existing destination. It never reads or stores a tunnel token.
Automatic cloudflared updates are disabled; upgrades require a reviewed manifest change.`;
}

function safeError(error) {
  return {
    ok: false,
    error: {
      code: error?.code ?? "unexpected_error",
      message: error instanceof Error ? error.message : "unexpected failure",
    },
  };
}

export async function main({
  argv = process.argv.slice(2),
  stdout = process.stdout,
  stderr = process.stderr,
  fetchImpl = globalThis.fetch,
} = {}) {
  try {
    const options = parseCommandOptions(argv, RUNTIME_COMMAND_OPTIONS, (message) =>
      fail("invalid_arguments", message),
    );
    if (options.help) {
      stdout.write(`${usage()}\n`);
      return 0;
    }
    if (!options.destination || !options.receiptPath) {
      fail("invalid_arguments", `${options.command} requires --destination and --receipt`);
    }
    if (options.command !== "install" && options.confirmation !== null) {
      fail("invalid_arguments", "--confirm is valid only for install");
    }
    const manifest = await loadRuntimeManifest(options.manifestPath);
    let result;
    if (options.command === "plan") {
      result = createRuntimePlan({
        manifest,
        destination: options.destination,
        receiptPath: options.receiptPath,
      });
    } else if (options.command === "install") {
      result = await installPinnedRuntime({
        manifest,
        destination: options.destination,
        receiptPath: options.receiptPath,
        confirmation: options.confirmation,
        fetchImpl,
      });
    } else {
      result = await verifyPinnedRuntime({
        manifest,
        binaryPath: options.destination,
        receiptPath: options.receiptPath,
      });
    }
    stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return 0;
  } catch (error) {
    stderr.write(`${JSON.stringify(safeError(error), null, 2)}\n`);
    return 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  process.exitCode = await main();
}
