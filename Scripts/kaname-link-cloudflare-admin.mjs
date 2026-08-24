#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import {
  chmod,
  lstat,
  readFile,
  rename,
  unlink,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  canonicalJSON,
  parseCommandOptions,
  rejectUnexpectedKeys,
  validateExternalFilePath,
} from "./kaname-link-delivery-common.mjs";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REPOSITORY_ROOT = path.resolve(path.dirname(SCRIPT_PATH), "..");
const DEFAULT_DESIRED_STATE_PATH = path.join(
  REPOSITORY_ROOT,
  "Infrastructure",
  "KanameLinkTunnel",
  "desired-state.json",
);
const CLOUDFLARE_API_ORIGIN = "https://api.cloudflare.com";
const CLOUDFLARE_API_PREFIX = "/client/v4";
const ACCOUNT_OR_ZONE_ID = /^[0-9a-f]{32}$/i;
const TUNNEL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DNS_RECORD_ID = /^[0-9a-f]{32}$/i;
const TUNNEL_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;
const HOSTNAME = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const RECEIPT_SCHEMA_VERSION = 1;
const RECEIPT_STATES = new Set([
  "provisioning",
  "applied",
  "rolled_back",
  "rollback_failed",
  "destroy_failed",
  "destroyed",
]);
const ACTIVE_TUNNEL_STATES = new Set(["healthy", "degraded"]);

export class DeliveryError extends Error {
  constructor(code, message, options = {}) {
    super(message, options);
    this.name = "DeliveryError";
    this.code = code;
  }
}

export class CloudflareAPIError extends DeliveryError {
  constructor({ method, pathname, status, codes = [], messages = [] }) {
    const codeSummary = codes.length > 0 ? `; codes=${codes.join(",")}` : "";
    const messageSummary = messages.length > 0 ? `; ${messages.join(" | ")}` : "";
    super(
      "cloudflare_api_error",
      `Cloudflare API ${method} ${pathname} failed (${status}${codeSummary}${messageSummary})`,
    );
    this.name = "CloudflareAPIError";
    this.status = status;
  }
}

function fail(code, message, options) {
  throw new DeliveryError(code, message, options);
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requirePlainObject(value, label) {
  if (!isPlainObject(value)) {
    fail("invalid_configuration", `${label} must be a JSON object`);
  }
  return value;
}

function requireExactKeys(object, allowedKeys, label) {
  rejectUnexpectedKeys(object, allowedKeys, label, (message) =>
    fail("invalid_configuration", message),
  );
}

function requireString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    fail("invalid_configuration", `${label} must be a non-empty string`);
  }
  return value;
}

function normalizeHostname(value) {
  return value.toLowerCase().replace(/\.$/, "");
}

function normalizeCNAME(value) {
  return normalizeHostname(value);
}

function requireIdentifier(value, expression, label) {
  if (typeof value !== "string" || !expression.test(value)) {
    fail("invalid_identifier", `${label} is not a valid identifier`);
  }
  return value;
}

function nowISO(clock) {
  return new Date(clock()).toISOString();
}

function cloneJSON(value) {
  return JSON.parse(JSON.stringify(value));
}

export function normalizeDesiredState(raw) {
  const desired = requirePlainObject(raw, "desired state");
  requireExactKeys(
    desired,
    [
      "schemaVersion",
      "tunnelName",
      "zoneName",
      "hostname",
      "publicPathRegex",
      "originService",
      "originRequest",
      "catchAllService",
      "dns",
    ],
    "desired state",
  );
  if (desired.schemaVersion !== 1) {
    fail("invalid_configuration", "desired state schemaVersion must be 1");
  }

  const tunnelName = requireString(desired.tunnelName, "tunnelName").toLowerCase();
  if (!TUNNEL_NAME.test(tunnelName)) {
    fail("invalid_configuration", "tunnelName must contain only lowercase letters, digits, and hyphens");
  }
  const zoneName = normalizeHostname(requireString(desired.zoneName, "zoneName"));
  const hostname = normalizeHostname(requireString(desired.hostname, "hostname"));
  if (!HOSTNAME.test(zoneName) || !HOSTNAME.test(hostname)) {
    fail("invalid_configuration", "zoneName and hostname must be valid DNS hostnames");
  }
  if (!hostname.endsWith(`.${zoneName}`) || hostname === zoneName) {
    fail("invalid_configuration", "hostname must be a subdomain of zoneName");
  }
  if (desired.publicPathRegex !== "^/v1/(enroll|rpc)$") {
    fail(
      "invalid_configuration",
      "publicPathRegex must expose only the exact /v1/enroll and /v1/rpc paths",
    );
  }

  const originService = requireString(desired.originService, "originService");
  let originURL;
  try {
    originURL = new URL(originService);
  } catch {
    fail("invalid_configuration", "originService must be an absolute URL");
  }
  if (
    originURL.protocol !== "http:" ||
    originURL.hostname !== "127.0.0.1" ||
    originURL.port === "" ||
    originURL.pathname !== "/" ||
    originURL.search !== "" ||
    originURL.hash !== "" ||
    originURL.username !== "" ||
    originURL.password !== ""
  ) {
    fail(
      "invalid_configuration",
      "originService must be an explicit http://127.0.0.1:<port> loopback URL",
    );
  }
  const originPort = Number(originURL.port);
  if (!Number.isSafeInteger(originPort) || originPort < 1 || originPort > 65_535) {
    fail("invalid_configuration", "originService port is invalid");
  }

  const originRequest = requirePlainObject(desired.originRequest, "originRequest");
  requireExactKeys(originRequest, ["connectTimeout", "httpHostHeader"], "originRequest");
  const connectTimeout = requireString(originRequest.connectTimeout, "originRequest.connectTimeout");
  if (!/^[1-9][0-9]*s$/.test(connectTimeout)) {
    fail("invalid_configuration", "originRequest.connectTimeout must be a positive duration in seconds");
  }
  if (
    normalizeHostname(
      requireString(originRequest.httpHostHeader, "originRequest.httpHostHeader"),
    ) !== hostname
  ) {
    fail("invalid_configuration", "originRequest.httpHostHeader must equal hostname");
  }
  if (desired.catchAllService !== "http_status:404") {
    fail("invalid_configuration", "catchAllService must be http_status:404");
  }

  const dns = requirePlainObject(desired.dns, "dns");
  requireExactKeys(dns, ["type", "proxied", "ttl"], "dns");
  if (dns.type !== "CNAME" || dns.proxied !== true || dns.ttl !== 1) {
    fail("invalid_configuration", "dns must be a proxied CNAME with ttl 1 (automatic)");
  }

  return {
    schemaVersion: 1,
    tunnelName,
    zoneName,
    hostname,
    publicPathRegex: "^/v1/(enroll|rpc)$",
    originService: originURL.origin,
    originRequest: {
      connectTimeout,
      httpHostHeader: hostname,
    },
    catchAllService: "http_status:404",
    dns: {
      type: "CNAME",
      proxied: true,
      ttl: 1,
    },
  };
}

export async function loadDesiredState(filePath = DEFAULT_DESIRED_STATE_PATH) {
  const resolvedPath = path.resolve(filePath);
  let parsed;
  try {
    parsed = JSON.parse(await readFile(resolvedPath, "utf8"));
  } catch (error) {
    fail("invalid_configuration", `unable to read desired state at ${resolvedPath}`, { cause: error });
  }
  return normalizeDesiredState(parsed);
}

export function desiredStateDigest(desired) {
  return createHash("sha256").update(canonicalJSON(normalizeDesiredState(desired))).digest("hex");
}

export function createIngressConfiguration(desiredInput) {
  const desired = normalizeDesiredState(desiredInput);
  return {
    ingress: [
      {
        hostname: desired.hostname,
        path: desired.publicPathRegex,
        service: desired.originService,
        originRequest: cloneJSON(desired.originRequest),
      },
      {
        service: desired.catchAllService,
      },
    ],
  };
}

export function createDenyAllConfiguration(desiredInput) {
  const desired = normalizeDesiredState(desiredInput);
  return {
    ingress: [{ service: desired.catchAllService }],
  };
}

function sanitizeCloudflareMessages(payload, token) {
  const messages = [];
  const codes = [];
  for (const entry of Array.isArray(payload?.errors) ? payload.errors : []) {
    if (entry && (typeof entry.code === "number" || typeof entry.code === "string")) {
      codes.push(String(entry.code).slice(0, 64));
    }
    if (entry && typeof entry.message === "string") {
      let message = entry.message.replaceAll(token, "[redacted]");
      message = message.replace(/Bearer\s+[A-Za-z0-9._~-]+/gi, "Bearer [redacted]");
      messages.push(message.slice(0, 300));
    }
  }
  return { codes, messages };
}

export class CloudflareAPI {
  #token;
  #fetchImpl;
  #timeoutMilliseconds;

  constructor({ token, fetchImpl = globalThis.fetch, timeoutMilliseconds = 15_000 } = {}) {
    if (typeof token !== "string" || token.length < 8) {
      fail("missing_credentials", "CLOUDFLARE_API_TOKEN is required");
    }
    if (typeof fetchImpl !== "function") {
      fail("invalid_runtime", "a Fetch implementation is required");
    }
    this.#token = token;
    this.#fetchImpl = fetchImpl;
    this.#timeoutMilliseconds = timeoutMilliseconds;
  }

  async request(method, pathname, { query, body } = {}) {
    if (!pathname.startsWith("/")) {
      fail("invalid_request", "Cloudflare API pathname must be absolute");
    }
    const url = new URL(`${CLOUDFLARE_API_PREFIX}${pathname}`, CLOUDFLARE_API_ORIGIN);
    if (url.origin !== CLOUDFLARE_API_ORIGIN || !url.pathname.startsWith(`${CLOUDFLARE_API_PREFIX}/`)) {
      fail("invalid_request", "Cloudflare API URL escaped the fixed API origin");
    }
    for (const [key, value] of Object.entries(query ?? {})) {
      if (value !== undefined && value !== null) {
        url.searchParams.set(key, String(value));
      }
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.#timeoutMilliseconds);
    let response;
    let payload = null;
    try {
      response = await this.#fetchImpl(url, {
        method,
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${this.#token}`,
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: "error",
        signal: controller.signal,
      });
      if (response.status !== 204) {
        const text = await response.text();
        if (text.length === 0) {
          fail("cloudflare_invalid_response", `Cloudflare API ${method} ${pathname} returned an empty body`);
        }
        try {
          payload = JSON.parse(text);
        } catch (error) {
          fail(
            "cloudflare_invalid_response",
            `Cloudflare API ${method} ${pathname} returned invalid JSON`,
            { cause: error },
          );
        }
      }
    } catch (error) {
      if (error instanceof DeliveryError) throw error;
      const reason = error?.name === "AbortError" ? "timed out" : "failed before a response";
      throw new DeliveryError(
        "cloudflare_transport_error",
        `Cloudflare API ${method} ${pathname} ${reason}`,
        { cause: error },
      );
    } finally {
      clearTimeout(timeout);
    }
    if (!response.ok || payload?.success === false) {
      const { codes, messages } = sanitizeCloudflareMessages(payload, this.#token);
      throw new CloudflareAPIError({ method, pathname, status: response.status, codes, messages });
    }
    return payload?.result ?? null;
  }

  async listTunnels(accountId, tunnelName) {
    return this.request("GET", `/accounts/${accountId}/cfd_tunnel`, {
      query: { name: tunnelName, is_deleted: false, per_page: 50 },
    });
  }

  async getTunnel(accountId, tunnelId) {
    return this.request("GET", `/accounts/${accountId}/cfd_tunnel/${tunnelId}`);
  }

  async createTunnel(accountId, tunnelName) {
    return this.request("POST", `/accounts/${accountId}/cfd_tunnel`, {
      body: { name: tunnelName, config_src: "cloudflare" },
    });
  }

  async deleteTunnel(accountId, tunnelId) {
    return this.request("DELETE", `/accounts/${accountId}/cfd_tunnel/${tunnelId}`);
  }

  async getTunnelConfiguration(accountId, tunnelId) {
    return this.request("GET", `/accounts/${accountId}/cfd_tunnel/${tunnelId}/configurations`);
  }

  async putTunnelConfiguration(accountId, tunnelId, configuration) {
    return this.request("PUT", `/accounts/${accountId}/cfd_tunnel/${tunnelId}/configurations`, {
      body: { config: configuration },
    });
  }

  async listDNSRecords(zoneId, hostname) {
    return this.request("GET", `/zones/${zoneId}/dns_records`, {
      query: { name: hostname, match: "all", per_page: 100 },
    });
  }

  async getDNSRecord(zoneId, recordId) {
    return this.request("GET", `/zones/${zoneId}/dns_records/${recordId}`);
  }

  async createDNSRecord(zoneId, record) {
    return this.request("POST", `/zones/${zoneId}/dns_records`, { body: record });
  }

  async deleteDNSRecord(zoneId, recordId) {
    return this.request("DELETE", `/zones/${zoneId}/dns_records/${recordId}`);
  }
}

function validateCloudIdentifiers(accountId, zoneId) {
  return {
    accountId: requireIdentifier(accountId, ACCOUNT_OR_ZONE_ID, "CLOUDFLARE_ACCOUNT_ID"),
    zoneId: requireIdentifier(zoneId, ACCOUNT_OR_ZONE_ID, "CLOUDFLARE_ZONE_ID"),
  };
}

export function validateReceiptPath(receiptPath, repositoryRoot = REPOSITORY_ROOT) {
  return validateExternalFilePath(receiptPath, repositoryRoot, "receipt path", (message) =>
    fail("invalid_receipt_path", message),
  );
}

function validateReceiptIdentity(receipt, { desired, accountId, zoneId }) {
  requirePlainObject(receipt, "receipt");
  if (receipt.schemaVersion !== RECEIPT_SCHEMA_VERSION) {
    fail("receipt_mismatch", "receipt schemaVersion is unsupported");
  }
  if (!RECEIPT_STATES.has(receipt.state)) {
    fail("receipt_mismatch", "receipt state is unsupported");
  }
  if (
    receipt.desiredStateDigest !== desiredStateDigest(desired) ||
    receipt.accountId !== accountId ||
    receipt.zoneId !== zoneId ||
    receipt.tunnelName !== desired.tunnelName ||
    receipt.hostname !== desired.hostname
  ) {
    fail("receipt_mismatch", "receipt does not match the exact desired state and Cloudflare scope");
  }
  if (receipt.tunnelId !== null) {
    requireIdentifier(receipt.tunnelId, TUNNEL_ID, "receipt tunnelId");
  }
  if (receipt.dnsRecordId !== null) {
    requireIdentifier(receipt.dnsRecordId, DNS_RECORD_ID, "receipt dnsRecordId");
  }
  if (typeof receipt.createdTunnel !== "boolean" || typeof receipt.createdDNSRecord !== "boolean") {
    fail("receipt_mismatch", "receipt ownership flags are invalid");
  }
  return receipt;
}

export async function readReceipt(receiptPath, options = {}) {
  const resolved = validateReceiptPath(receiptPath, options.repositoryRoot);
  let metadata;
  try {
    metadata = await lstat(resolved);
  } catch (error) {
    if (error?.code === "ENOENT" && options.optional === true) {
      return null;
    }
    fail("receipt_missing", `receipt does not exist at ${resolved}`, { cause: error });
  }
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    fail("invalid_receipt_path", "receipt must be a regular file, not a symlink");
  }
  if ((metadata.mode & 0o077) !== 0) {
    fail("invalid_receipt_permissions", "receipt must not be readable or writable by group or other users");
  }
  try {
    return JSON.parse(await readFile(resolved, "utf8"));
  } catch (error) {
    fail("invalid_receipt", "receipt is not valid JSON", { cause: error });
  }
}

export async function writeReceipt(receiptPath, receipt, options = {}) {
  const resolved = validateReceiptPath(receiptPath, options.repositoryRoot);
  const parent = path.dirname(resolved);
  let parentMetadata;
  try {
    parentMetadata = await lstat(parent);
  } catch (error) {
    fail("invalid_receipt_path", `receipt parent directory does not exist: ${parent}`, { cause: error });
  }
  if (!parentMetadata.isDirectory() || parentMetadata.isSymbolicLink()) {
    fail("invalid_receipt_path", "receipt parent must be a real directory, not a symlink");
  }
  const temporary = path.join(parent, `.${path.basename(resolved)}.${randomUUID()}.tmp`);
  try {
    await writeFile(temporary, `${JSON.stringify(receipt, null, 2)}\n`, { encoding: "utf8", mode: 0o600, flag: "wx" });
    await rename(temporary, resolved);
    await chmod(resolved, 0o600);
  } catch (error) {
    try {
      await unlink(temporary);
    } catch {
      // The temporary file may not have been created or may already have been renamed.
    }
    fail("receipt_write_failed", `unable to write receipt at ${resolved}`, { cause: error });
  }
}

function createReceipt({ desired, accountId, zoneId, clock }) {
  const timestamp = nowISO(clock);
  return {
    schemaVersion: RECEIPT_SCHEMA_VERSION,
    desiredStateDigest: desiredStateDigest(desired),
    accountId,
    zoneId,
    tunnelName: desired.tunnelName,
    hostname: desired.hostname,
    state: "provisioning",
    tunnelId: null,
    dnsRecordId: null,
    createdTunnel: false,
    createdDNSRecord: false,
    configurationApplied: false,
    createdAt: timestamp,
    updatedAt: timestamp,
    lastErrorCode: null,
  };
}

function updateReceipt(receipt, clock, changes) {
  Object.assign(receipt, changes, { updatedAt: nowISO(clock) });
  return receipt;
}

function requireArray(value, label) {
  if (!Array.isArray(value)) {
    fail("unexpected_cloudflare_response", `${label} was not an array`);
  }
  return value;
}

function expectedTunnelTarget(tunnelId) {
  return `${tunnelId.toLowerCase()}.cfargotunnel.com`;
}

function assertTunnelMatches(tunnel, desired, expectedId) {
  requirePlainObject(tunnel, "Cloudflare tunnel");
  if (tunnel.id !== expectedId || tunnel.name !== desired.tunnelName) {
    fail("tunnel_identity_mismatch", "Cloudflare tunnel ID or name does not match the receipt");
  }
  if (tunnel.deleted_at !== undefined && tunnel.deleted_at !== null) {
    fail("tunnel_identity_mismatch", "Cloudflare tunnel is deleted");
  }
  if (tunnel.config_src !== undefined && tunnel.config_src !== "cloudflare") {
    fail("tunnel_identity_mismatch", "Cloudflare tunnel is not remotely managed");
  }
  if (tunnel.tun_type !== undefined && tunnel.tun_type !== "cfd_tunnel") {
    fail("tunnel_identity_mismatch", "Cloudflare tunnel has an unexpected type");
  }
  return tunnel;
}

function assertDNSRecordMatches(record, desired, tunnelId, expectedId) {
  requirePlainObject(record, "Cloudflare DNS record");
  if (
    record.id !== expectedId ||
    normalizeHostname(record.name ?? "") !== desired.hostname ||
    record.type !== desired.dns.type ||
    normalizeCNAME(record.content ?? "") !== expectedTunnelTarget(tunnelId) ||
    record.proxied !== true ||
    record.ttl !== desired.dns.ttl
  ) {
    fail("dns_identity_mismatch", "Cloudflare DNS record does not exactly match the receipt and desired state");
  }
  return record;
}

function normalizeIngressRule(rule) {
  requirePlainObject(rule, "tunnel ingress rule");
  requireExactKeys(rule, ["hostname", "service", "originRequest", "path"], "tunnel ingress rule");
  const normalized = { service: rule.service };
  if (rule.hostname !== undefined) normalized.hostname = normalizeHostname(rule.hostname);
  if (rule.path !== undefined) normalized.path = rule.path;
  if (rule.originRequest !== undefined) normalized.originRequest = cloneJSON(rule.originRequest);
  return normalized;
}

function assertConfigurationMatches(configurationResponse, desired) {
  const response = requirePlainObject(configurationResponse, "Cloudflare tunnel configuration");
  const configuration = requirePlainObject(response.config ?? response, "Cloudflare tunnel config");
  const allowedTopLevel = new Set(["ingress", "originRequest", "warp-routing"]);
  const unsupported = Object.keys(configuration).filter((key) => !allowedTopLevel.has(key));
  if (unsupported.length > 0) {
    fail("configuration_drift", `tunnel config has unsupported key(s): ${unsupported.sort().join(", ")}`);
  }
  if (configuration.originRequest !== undefined && Object.keys(configuration.originRequest).length > 0) {
    fail("configuration_drift", "tunnel config has unexpected global originRequest settings");
  }
  if (configuration["warp-routing"]?.enabled === true) {
    fail("configuration_drift", "tunnel config unexpectedly enables WARP routing");
  }
  const actualIngress = requireArray(configuration.ingress, "tunnel ingress").map(normalizeIngressRule);
  const expectedIngress = createIngressConfiguration(desired).ingress.map(normalizeIngressRule);
  if (canonicalJSON(actualIngress) !== canonicalJSON(expectedIngress)) {
    fail("configuration_drift", "tunnel ingress rules do not exactly match desired state");
  }
  return configuration;
}

function isNotFound(error) {
  return error instanceof CloudflareAPIError && error.status === 404;
}

async function getOptionalTunnel(client, accountId, tunnelId) {
  try {
    return await client.getTunnel(accountId, tunnelId);
  } catch (error) {
    if (isNotFound(error)) return null;
    throw error;
  }
}

async function getOptionalDNSRecord(client, zoneId, recordId) {
  try {
    return await client.getDNSRecord(zoneId, recordId);
  } catch (error) {
    if (isNotFound(error)) return null;
    throw error;
  }
}

function exactNamedTunnels(tunnels, desired) {
  return requireArray(tunnels, "Cloudflare tunnel list").filter(
    (tunnel) => tunnel?.name === desired.tunnelName && tunnel?.deleted_at == null,
  );
}

function exactHostnameRecords(records, desired) {
  return requireArray(records, "Cloudflare DNS record list").filter(
    (record) => normalizeHostname(record?.name ?? "") === desired.hostname,
  );
}

export async function planDelivery({ client, desired: desiredInput, accountId, zoneId, receipt = null }) {
  const desired = normalizeDesiredState(desiredInput);
  ({ accountId, zoneId } = validateCloudIdentifiers(accountId, zoneId));
  if (receipt !== null) validateReceiptIdentity(receipt, { desired, accountId, zoneId });

  const [tunnelResults, dnsResults] = await Promise.all([
    client.listTunnels(accountId, desired.tunnelName),
    client.listDNSRecords(zoneId, desired.hostname),
  ]);
  const tunnels = exactNamedTunnels(tunnelResults, desired);
  const dnsRecords = exactHostnameRecords(dnsResults, desired);
  const blockers = [];
  let tunnelDisposition = "absent";
  let dnsDisposition = "absent";

  if (tunnels.length > 1) {
    blockers.push("multiple active tunnels have the exact desired name");
    tunnelDisposition = "collision";
  } else if (tunnels.length === 1) {
    if (receipt?.tunnelId === tunnels[0].id && receipt.createdTunnel === true) {
      assertTunnelMatches(tunnels[0], desired, receipt.tunnelId);
      tunnelDisposition = "owned";
    } else {
      blockers.push("an unowned tunnel already has the exact desired name");
      tunnelDisposition = "collision";
    }
  } else if (receipt?.tunnelId !== null && receipt?.tunnelId !== undefined) {
    blockers.push("the receipt-owned tunnel ID is missing");
    tunnelDisposition = "missing_owned_resource";
  }

  if (dnsRecords.length > 1) {
    blockers.push("multiple DNS records already use the exact desired hostname");
    dnsDisposition = "collision";
  } else if (dnsRecords.length === 1) {
    if (receipt?.dnsRecordId === dnsRecords[0].id && receipt.createdDNSRecord === true) {
      if (!receipt.tunnelId) {
        blockers.push("receipt has a DNS record but no tunnel ID");
        dnsDisposition = "collision";
      } else {
        assertDNSRecordMatches(dnsRecords[0], desired, receipt.tunnelId, receipt.dnsRecordId);
        dnsDisposition = "owned";
      }
    } else {
      blockers.push("an unowned DNS record already uses the exact desired hostname");
      dnsDisposition = "collision";
    }
  } else if (receipt?.dnsRecordId !== null && receipt?.dnsRecordId !== undefined) {
    blockers.push("the receipt-owned DNS record ID is missing");
    dnsDisposition = "missing_owned_resource";
  }

  if (receipt && !["provisioning", "applied"].includes(receipt.state)) {
    blockers.push(`receipt state ${receipt.state} cannot be reused for apply`);
  }

  const actions = [];
  if (receipt?.state !== "applied") {
    if (tunnelDisposition === "absent") actions.push("create_tunnel");
    if (tunnelDisposition === "absent" || tunnelDisposition === "owned") {
      actions.push("put_exact_ingress_configuration");
    }
    if (dnsDisposition === "absent") actions.push("create_proxied_cname");
  }
  actions.push("verify_exact_ids_and_configuration");

  return {
    ok: blockers.length === 0,
    operation: "plan",
    desiredStateDigest: desiredStateDigest(desired),
    tunnel: {
      name: desired.tunnelName,
      disposition: tunnelDisposition,
      id: tunnels[0]?.id ?? receipt?.tunnelId ?? null,
    },
    dns: {
      hostname: desired.hostname,
      disposition: dnsDisposition,
      id: dnsRecords[0]?.id ?? receipt?.dnsRecordId ?? null,
    },
    actions,
    blockers,
  };
}

export async function verifyDelivery({ client, desired: desiredInput, accountId, zoneId, receipt }) {
  const desired = normalizeDesiredState(desiredInput);
  ({ accountId, zoneId } = validateCloudIdentifiers(accountId, zoneId));
  validateReceiptIdentity(receipt, { desired, accountId, zoneId });
  if (receipt.state !== "applied") {
    fail("receipt_state_invalid", `verify requires an applied receipt, found ${receipt.state}`);
  }
  if (!receipt.tunnelId || !receipt.dnsRecordId) {
    fail("receipt_mismatch", "applied receipt is missing exact resource IDs");
  }

  const [tunnel, configuration, dnsRecord, tunnelResults, dnsResults] = await Promise.all([
    client.getTunnel(accountId, receipt.tunnelId),
    client.getTunnelConfiguration(accountId, receipt.tunnelId),
    client.getDNSRecord(zoneId, receipt.dnsRecordId),
    client.listTunnels(accountId, desired.tunnelName),
    client.listDNSRecords(zoneId, desired.hostname),
  ]);
  assertTunnelMatches(tunnel, desired, receipt.tunnelId);
  assertConfigurationMatches(configuration, desired);
  assertDNSRecordMatches(dnsRecord, desired, receipt.tunnelId, receipt.dnsRecordId);

  const namedTunnels = exactNamedTunnels(tunnelResults, desired);
  if (namedTunnels.length !== 1 || namedTunnels[0].id !== receipt.tunnelId) {
    fail("tunnel_collision", "tunnel name no longer resolves to the one receipt-owned ID");
  }
  const hostnameRecords = exactHostnameRecords(dnsResults, desired);
  if (hostnameRecords.length !== 1 || hostnameRecords[0].id !== receipt.dnsRecordId) {
    fail("dns_collision", "hostname no longer resolves to the one receipt-owned DNS record ID");
  }

  return {
    ok: true,
    operation: "verify",
    desiredStateDigest: receipt.desiredStateDigest,
    tunnel: {
      id: receipt.tunnelId,
      name: desired.tunnelName,
      status: tunnel.status ?? "unknown",
      connectorReady: tunnel.status === "healthy",
    },
    dns: {
      id: receipt.dnsRecordId,
      hostname: desired.hostname,
      target: expectedTunnelTarget(receipt.tunnelId),
      proxied: true,
    },
  };
}

async function putDenyAllIfPresent({ client, desired, accountId, receipt }) {
  if (!receipt.tunnelId) return false;
  const tunnel = await getOptionalTunnel(client, accountId, receipt.tunnelId);
  if (!tunnel) return false;
  assertTunnelMatches(tunnel, desired, receipt.tunnelId);
  await client.putTunnelConfiguration(
    accountId,
    receipt.tunnelId,
    createDenyAllConfiguration(desired),
  );
  return true;
}

async function deleteExactDNSIfPresent({ client, desired, zoneId, receipt }) {
  if (!receipt.createdDNSRecord || !receipt.dnsRecordId || !receipt.tunnelId) return false;
  const record = await getOptionalDNSRecord(client, zoneId, receipt.dnsRecordId);
  if (!record) {
    const collisions = exactHostnameRecords(
      await client.listDNSRecords(zoneId, desired.hostname),
      desired,
    );
    if (collisions.length > 0) {
      fail("dns_collision", "receipt DNS ID is absent but another record now uses the hostname");
    }
    return false;
  }
  assertDNSRecordMatches(record, desired, receipt.tunnelId, receipt.dnsRecordId);
  await client.deleteDNSRecord(zoneId, receipt.dnsRecordId);
  return true;
}

async function deleteExactTunnelIfPresent({ client, desired, accountId, receipt, allowActive }) {
  if (!receipt.createdTunnel || !receipt.tunnelId) return false;
  const tunnel = await getOptionalTunnel(client, accountId, receipt.tunnelId);
  if (!tunnel) {
    const collisions = exactNamedTunnels(
      await client.listTunnels(accountId, desired.tunnelName),
      desired,
    );
    if (collisions.length > 0) {
      fail("tunnel_collision", "receipt tunnel ID is absent but another tunnel now uses the name");
    }
    return false;
  }
  assertTunnelMatches(tunnel, desired, receipt.tunnelId);
  if (!allowActive && ACTIVE_TUNNEL_STATES.has(tunnel.status)) {
    fail(
      "connector_still_active",
      `refusing to destroy tunnel while connector status is ${tunnel.status}; stop the connector first`,
    );
  }
  await client.deleteTunnel(accountId, receipt.tunnelId);
  return true;
}

async function rollbackProvisioning({
  client,
  desired,
  accountId,
  zoneId,
  receipt,
  receiptPath,
  clock,
  receiptOptions,
  creationAttempts,
}) {
  const rollbackErrors = [];
  let preserveKnownTunnel = false;
  try {
    await putDenyAllIfPresent({ client, desired, accountId, receipt });
  } catch (error) {
    rollbackErrors.push(error?.code ?? "rollback_deny_all_failed");
  }

  if (creationAttempts.tunnel && !receipt.tunnelId) {
    try {
      const possibleTunnels = exactNamedTunnels(
        await client.listTunnels(accountId, desired.tunnelName),
        desired,
      );
      if (possibleTunnels.length > 0) {
        rollbackErrors.push("tunnel_create_outcome_ambiguous");
      }
    } catch (error) {
      rollbackErrors.push(error?.code ?? "tunnel_create_outcome_check_failed");
    }
  }

  if (creationAttempts.dns && !receipt.dnsRecordId) {
    try {
      const possibleRecords = exactHostnameRecords(
        await client.listDNSRecords(zoneId, desired.hostname),
        desired,
      );
      if (possibleRecords.length > 0) {
        rollbackErrors.push("dns_create_outcome_ambiguous");
        preserveKnownTunnel = true;
      }
    } catch (error) {
      rollbackErrors.push(error?.code ?? "dns_create_outcome_check_failed");
      preserveKnownTunnel = true;
    }
  }

  try {
    await deleteExactDNSIfPresent({ client, desired, zoneId, receipt });
  } catch (error) {
    rollbackErrors.push(error?.code ?? "rollback_dns_delete_failed");
    preserveKnownTunnel = true;
  }
  if (!preserveKnownTunnel) {
    try {
      await deleteExactTunnelIfPresent({
        client,
        desired,
        accountId,
        receipt,
        allowActive: true,
      });
    } catch (error) {
      rollbackErrors.push(error?.code ?? "rollback_tunnel_delete_failed");
    }
  }
  updateReceipt(receipt, clock, {
    state: rollbackErrors.length === 0 ? "rolled_back" : "rollback_failed",
    rollbackErrorCodes: rollbackErrors,
  });
  await writeReceipt(receiptPath, receipt, receiptOptions);
  return rollbackErrors;
}

export async function applyDelivery({
  client,
  desired: desiredInput,
  accountId,
  zoneId,
  receiptPath,
  receipt = null,
  clock = Date.now,
  receiptOptions = {},
}) {
  const desired = normalizeDesiredState(desiredInput);
  ({ accountId, zoneId } = validateCloudIdentifiers(accountId, zoneId));
  validateReceiptPath(receiptPath, receiptOptions.repositoryRoot);
  if (receipt !== null) validateReceiptIdentity(receipt, { desired, accountId, zoneId });
  if (receipt?.state === "applied") {
    const verification = await verifyDelivery({ client, desired, accountId, zoneId, receipt });
    return { ...verification, operation: "apply", alreadyApplied: true };
  }
  if (receipt !== null && receipt.state !== "provisioning") {
    fail("receipt_state_invalid", `apply cannot reuse receipt state ${receipt.state}`);
  }

  const plan = await planDelivery({ client, desired, accountId, zoneId, receipt });
  if (!plan.ok) {
    fail("apply_blocked", `apply blocked: ${plan.blockers.join("; ")}`);
  }
  if (receipt === null) {
    receipt = createReceipt({ desired, accountId, zoneId, clock });
    await writeReceipt(receiptPath, receipt, receiptOptions);
  }

  const creationAttempts = { tunnel: false, dns: false };
  try {
    if (!receipt.tunnelId) {
      creationAttempts.tunnel = true;
      const tunnel = await client.createTunnel(accountId, desired.tunnelName);
      requireIdentifier(tunnel?.id, TUNNEL_ID, "created tunnel ID");
      assertTunnelMatches(tunnel, desired, tunnel.id);
      updateReceipt(receipt, clock, {
        tunnelId: tunnel.id,
        createdTunnel: true,
      });
      await writeReceipt(receiptPath, receipt, receiptOptions);
    }

    await client.putTunnelConfiguration(
      accountId,
      receipt.tunnelId,
      createIngressConfiguration(desired),
    );
    updateReceipt(receipt, clock, { configurationApplied: true });
    await writeReceipt(receiptPath, receipt, receiptOptions);

    if (!receipt.dnsRecordId) {
      creationAttempts.dns = true;
      const record = await client.createDNSRecord(zoneId, {
        type: desired.dns.type,
        name: desired.hostname,
        content: expectedTunnelTarget(receipt.tunnelId),
        proxied: desired.dns.proxied,
        ttl: desired.dns.ttl,
        comment: "Kaname Link production tunnel; managed by kaname-link-cloudflare-admin.mjs",
      });
      requireIdentifier(record?.id, DNS_RECORD_ID, "created DNS record ID");
      assertDNSRecordMatches(record, desired, receipt.tunnelId, record.id);
      updateReceipt(receipt, clock, {
        dnsRecordId: record.id,
        createdDNSRecord: true,
      });
      await writeReceipt(receiptPath, receipt, receiptOptions);
    }

    updateReceipt(receipt, clock, { state: "applied", lastErrorCode: null });
    await writeReceipt(receiptPath, receipt, receiptOptions);
    const verification = await verifyDelivery({ client, desired, accountId, zoneId, receipt });
    return { ...verification, operation: "apply", alreadyApplied: false };
  } catch (error) {
    updateReceipt(receipt, clock, { lastErrorCode: error?.code ?? "apply_failed" });
    const rollbackErrors = await rollbackProvisioning({
      client,
      desired,
      accountId,
      zoneId,
      receipt,
      receiptPath,
      clock,
      receiptOptions,
      creationAttempts,
    });
    if (rollbackErrors.length > 0) {
      throw new DeliveryError(
        "apply_and_rollback_failed",
        `apply failed and rollback was incomplete (${rollbackErrors.join(", ")}); retain the receipt`,
        { cause: error },
      );
    }
    throw error;
  }
}

export async function destroyDelivery({
  client,
  desired: desiredInput,
  accountId,
  zoneId,
  receiptPath,
  receipt,
  confirmation,
  clock = Date.now,
  receiptOptions = {},
}) {
  const desired = normalizeDesiredState(desiredInput);
  ({ accountId, zoneId } = validateCloudIdentifiers(accountId, zoneId));
  validateReceiptPath(receiptPath, receiptOptions.repositoryRoot);
  validateReceiptIdentity(receipt, { desired, accountId, zoneId });
  if (confirmation !== desired.hostname) {
    fail("confirmation_required", `destroy requires --confirm ${desired.hostname}`);
  }
  if (receipt.state === "destroyed") {
    return { ok: true, operation: "destroy", alreadyDestroyed: true };
  }
  if (!["applied", "destroy_failed"].includes(receipt.state)) {
    fail("receipt_state_invalid", `destroy cannot use receipt state ${receipt.state}`);
  }

  const tunnel = receipt.tunnelId
    ? await getOptionalTunnel(client, accountId, receipt.tunnelId)
    : null;
  if (tunnel) {
    assertTunnelMatches(tunnel, desired, receipt.tunnelId);
    if (ACTIVE_TUNNEL_STATES.has(tunnel.status)) {
      fail(
        "connector_still_active",
        `refusing to destroy tunnel while connector status is ${tunnel.status}; stop the connector first`,
      );
    }
  }

  try {
    await putDenyAllIfPresent({ client, desired, accountId, receipt });
    await deleteExactDNSIfPresent({ client, desired, zoneId, receipt });
    await deleteExactTunnelIfPresent({
      client,
      desired,
      accountId,
      receipt,
      allowActive: false,
    });

    const [remainingTunnels, remainingRecords] = await Promise.all([
      client.listTunnels(accountId, desired.tunnelName),
      client.listDNSRecords(zoneId, desired.hostname),
    ]);
    if (exactNamedTunnels(remainingTunnels, desired).length > 0) {
      fail("tunnel_collision", "a tunnel with the desired name remains after exact-ID destroy");
    }
    if (exactHostnameRecords(remainingRecords, desired).length > 0) {
      fail("dns_collision", "a DNS record with the desired hostname remains after exact-ID destroy");
    }

    updateReceipt(receipt, clock, {
      state: "destroyed",
      destroyedAt: nowISO(clock),
      lastErrorCode: null,
    });
    await writeReceipt(receiptPath, receipt, receiptOptions);
    return {
      ok: true,
      operation: "destroy",
      alreadyDestroyed: false,
      tunnelId: receipt.tunnelId,
      dnsRecordId: receipt.dnsRecordId,
    };
  } catch (error) {
    updateReceipt(receipt, clock, {
      state: "destroy_failed",
      lastErrorCode: error?.code ?? "destroy_failed",
    });
    await writeReceipt(receiptPath, receipt, receiptOptions);
    throw error;
  }
}

function usage() {
  return `Usage:
  node Scripts/kaname-link-cloudflare-admin.mjs plan [--desired-state PATH] [--receipt ABSOLUTE_PATH]
  node Scripts/kaname-link-cloudflare-admin.mjs apply --receipt ABSOLUTE_PATH [--desired-state PATH]
  node Scripts/kaname-link-cloudflare-admin.mjs verify --receipt ABSOLUTE_PATH [--desired-state PATH]
  node Scripts/kaname-link-cloudflare-admin.mjs destroy --receipt ABSOLUTE_PATH --confirm HOSTNAME [--desired-state PATH]

Environment (never print or commit these values):
  CLOUDFLARE_API_TOKEN   API token with Cloudflare Tunnel Edit and cyber-lane.com DNS Edit
  CLOUDFLARE_ACCOUNT_ID  Exact 32-character Cloudflare account ID
  CLOUDFLARE_ZONE_ID     Exact 32-character cyber-lane.com zone ID

The receipt parent directory must already exist outside this checkout. The receipt contains IDs only;
the tool never requests, prints, writes, or stores a Cloudflare Tunnel connector token.`;
}

function parseArguments(argv) {
  const options = parseCommandOptions(
    argv,
    {
      commands: ["plan", "apply", "verify", "destroy"],
      defaults: {
        desiredStatePath: DEFAULT_DESIRED_STATE_PATH,
        receiptPath: null,
        confirmation: null,
      },
      optionProperties: {
        "--desired-state": "desiredStatePath",
        "--receipt": "receiptPath",
        "--confirm": "confirmation",
      },
    },
    (message) => fail("invalid_arguments", message),
  );
  if (options.help) return options;
  if (options.command !== "plan" && !options.receiptPath) {
    fail("invalid_arguments", `${options.command} requires --receipt ABSOLUTE_PATH`);
  }
  if (options.command !== "destroy" && options.confirmation !== null) {
    fail("invalid_arguments", "--confirm is valid only for destroy");
  }
  return options;
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
  env = process.env,
  stdout = process.stdout,
  stderr = process.stderr,
  fetchImpl = globalThis.fetch,
} = {}) {
  try {
    const options = parseArguments(argv);
    if (options.help) {
      stdout.write(`${usage()}\n`);
      return 0;
    }
    const desired = await loadDesiredState(options.desiredStatePath);
    const { accountId, zoneId } = validateCloudIdentifiers(
      env.CLOUDFLARE_ACCOUNT_ID,
      env.CLOUDFLARE_ZONE_ID,
    );
    const client = new CloudflareAPI({ token: env.CLOUDFLARE_API_TOKEN, fetchImpl });
    const receipt = options.receiptPath
      ? await readReceipt(options.receiptPath, { optional: options.command === "plan" || options.command === "apply" })
      : null;

    let result;
    if (options.command === "plan") {
      result = await planDelivery({ client, desired, accountId, zoneId, receipt });
    } else if (options.command === "apply") {
      result = await applyDelivery({
        client,
        desired,
        accountId,
        zoneId,
        receiptPath: options.receiptPath,
        receipt,
      });
    } else if (options.command === "verify") {
      result = await verifyDelivery({ client, desired, accountId, zoneId, receipt });
    } else {
      result = await destroyDelivery({
        client,
        desired,
        accountId,
        zoneId,
        receiptPath: options.receiptPath,
        receipt,
        confirmation: options.confirmation,
      });
    }
    stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.ok === false ? 1 : 0;
  } catch (error) {
    stderr.write(`${JSON.stringify(safeError(error), null, 2)}\n`);
    return 1;
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : null;
if (invokedPath === import.meta.url) {
  process.exitCode = await main();
}
