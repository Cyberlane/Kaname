import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  CloudflareAPI,
  CloudflareAPIError,
  applyDelivery,
  createDenyAllConfiguration,
  createIngressConfiguration,
  desiredStateDigest,
  destroyDelivery,
  loadDesiredState,
  normalizeDesiredState,
  planDelivery,
  readReceipt,
  validateReceiptPath,
  verifyDelivery,
} from "../../Scripts/kaname-link-cloudflare-admin.mjs";

const TEST_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(TEST_DIRECTORY, "../..");
const DESIRED_STATE_PATH = path.join(
  REPOSITORY_ROOT,
  "Infrastructure",
  "KanameLinkTunnel",
  "desired-state.json",
);
const ACCOUNT_ID = "a".repeat(32);
const ZONE_ID = "b".repeat(32);
const TUNNEL_ID = "11111111-2222-4333-8444-555555555555";
const DNS_RECORD_ID = "c".repeat(32);
const OTHER_TUNNEL_ID = "99999999-8888-4777-8666-555555555555";
const OTHER_DNS_RECORD_ID = "d".repeat(32);
const FIXED_TIME = Date.parse("2026-08-24T12:00:00.000Z");
const clock = () => FIXED_TIME;

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function notFound(method, pathname) {
  return new CloudflareAPIError({ method, pathname, status: 404, codes: ["1001"] });
}

class FakeCloudflare {
  constructor(desired) {
    this.desired = desired;
    this.tunnels = new Map();
    this.configurations = new Map();
    this.dnsRecords = new Map();
    this.calls = [];
    this.failures = new Map();
  }

  failNext(operation, error = new Error(`${operation} failed`)) {
    this.failures.set(operation, error);
  }

  maybeFail(operation) {
    this.calls.push(operation);
    if (this.failures.has(operation)) {
      const error = this.failures.get(operation);
      this.failures.delete(operation);
      throw error;
    }
  }

  addTunnel({ id = TUNNEL_ID, name = this.desired.tunnelName, status = "inactive" } = {}) {
    const tunnel = {
      id,
      name,
      status,
      config_src: "cloudflare",
      tun_type: "cfd_tunnel",
      deleted_at: null,
    };
    this.tunnels.set(id, tunnel);
    return tunnel;
  }

  addDNSRecord({
    id = DNS_RECORD_ID,
    tunnelId = TUNNEL_ID,
    name = this.desired.hostname,
    type = "CNAME",
    proxied = true,
    ttl = 1,
  } = {}) {
    const record = {
      id,
      name,
      type,
      content: `${tunnelId}.cfargotunnel.com`,
      proxied,
      ttl,
    };
    this.dnsRecords.set(id, record);
    return record;
  }

  async listTunnels(_accountId, tunnelName) {
    this.maybeFail("listTunnels");
    return [...this.tunnels.values()].filter(
      (tunnel) => tunnel.name === tunnelName && tunnel.deleted_at == null,
    ).map(clone);
  }

  async getTunnel(_accountId, tunnelId) {
    this.maybeFail("getTunnel");
    const tunnel = this.tunnels.get(tunnelId);
    if (!tunnel) throw notFound("GET", `/cfd_tunnel/${tunnelId}`);
    return clone(tunnel);
  }

  async createTunnel(_accountId, tunnelName) {
    this.maybeFail("createTunnel");
    if ([...this.tunnels.values()].some((tunnel) => tunnel.name === tunnelName)) {
      throw new Error("duplicate tunnel name");
    }
    return clone(this.addTunnel({ name: tunnelName }));
  }

  async deleteTunnel(_accountId, tunnelId) {
    this.maybeFail("deleteTunnel");
    if (!this.tunnels.has(tunnelId)) throw notFound("DELETE", `/cfd_tunnel/${tunnelId}`);
    this.tunnels.delete(tunnelId);
    this.configurations.delete(tunnelId);
    return { id: tunnelId };
  }

  async getTunnelConfiguration(_accountId, tunnelId) {
    this.maybeFail("getTunnelConfiguration");
    if (!this.tunnels.has(tunnelId)) throw notFound("GET", `/configurations/${tunnelId}`);
    const configuration = this.configurations.get(tunnelId);
    if (!configuration) throw notFound("GET", `/configurations/${tunnelId}`);
    return { config: clone(configuration), tunnel_id: tunnelId };
  }

  async putTunnelConfiguration(_accountId, tunnelId, configuration) {
    this.maybeFail("putTunnelConfiguration");
    if (!this.tunnels.has(tunnelId)) throw notFound("PUT", `/configurations/${tunnelId}`);
    this.configurations.set(tunnelId, clone(configuration));
    return { config: clone(configuration), tunnel_id: tunnelId };
  }

  async listDNSRecords(_zoneId, hostname) {
    this.maybeFail("listDNSRecords");
    return [...this.dnsRecords.values()]
      .filter((record) => record.name === hostname)
      .map(clone);
  }

  async getDNSRecord(_zoneId, recordId) {
    this.maybeFail("getDNSRecord");
    const record = this.dnsRecords.get(recordId);
    if (!record) throw notFound("GET", `/dns_records/${recordId}`);
    return clone(record);
  }

  async createDNSRecord(_zoneId, record) {
    this.maybeFail("createDNSRecord");
    if ([...this.dnsRecords.values()].some((entry) => entry.name === record.name)) {
      throw new Error("duplicate DNS hostname");
    }
    const created = {
      id: DNS_RECORD_ID,
      name: record.name,
      type: record.type,
      content: record.content,
      proxied: record.proxied,
      ttl: record.ttl,
      comment: record.comment,
    };
    this.dnsRecords.set(created.id, created);
    return clone(created);
  }

  async deleteDNSRecord(_zoneId, recordId) {
    this.maybeFail("deleteDNSRecord");
    if (!this.dnsRecords.has(recordId)) throw notFound("DELETE", `/dns_records/${recordId}`);
    this.dnsRecords.delete(recordId);
    return { id: recordId };
  }
}

async function withTemporaryReceipt(run) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "kaname-link-tunnel-test-"));
  const receiptPath = path.join(directory, "receipt.json");
  try {
    return await run(receiptPath);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

async function applyFixture(fake, desired, receiptPath) {
  return applyDelivery({
    client: fake,
    desired,
    accountId: ACCOUNT_ID,
    zoneId: ZONE_ID,
    receiptPath,
    receipt: null,
    clock,
  });
}

test("checked-in desired state is the exact loopback-only tunnel contract", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  assert.deepEqual(desired, {
    schemaVersion: 1,
    tunnelName: "kaname-link-production",
    zoneName: "cyber-lane.com",
    hostname: "kaname-tunnel.cyber-lane.com",
    publicPathRegex: "^/v1/(enroll|rpc)$",
    originService: "http://127.0.0.1:43110",
    originRequest: {
      connectTimeout: "5s",
      httpHostHeader: "kaname-tunnel.cyber-lane.com",
    },
    catchAllService: "http_status:404",
    dns: { type: "CNAME", proxied: true, ttl: 1 },
  });
  assert.deepEqual(createIngressConfiguration(desired), {
    ingress: [
      {
        hostname: "kaname-tunnel.cyber-lane.com",
        path: "^/v1/(enroll|rpc)$",
        service: "http://127.0.0.1:43110",
        originRequest: {
          connectTimeout: "5s",
          httpHostHeader: "kaname-tunnel.cyber-lane.com",
        },
      },
      { service: "http_status:404" },
    ],
  });
  assert.deepEqual(createDenyAllConfiguration(desired), {
    ingress: [{ service: "http_status:404" }],
  });
  assert.match(desiredStateDigest(desired), /^[0-9a-f]{64}$/);
});

test("desired state rejects wildcard or non-loopback origins", () => {
  const base = {
    schemaVersion: 1,
    tunnelName: "kaname-link-production",
    zoneName: "cyber-lane.com",
    hostname: "kaname-tunnel.cyber-lane.com",
    publicPathRegex: "^/v1/(enroll|rpc)$",
    originService: "http://0.0.0.0:43110",
    originRequest: {
      connectTimeout: "5s",
      httpHostHeader: "kaname-tunnel.cyber-lane.com",
    },
    catchAllService: "http_status:404",
    dns: { type: "CNAME", proxied: true, ttl: 1 },
  };
  assert.throws(() => normalizeDesiredState(base), { code: "invalid_configuration" });
  assert.throws(
    () => normalizeDesiredState({ ...base, originService: "http://localhost:43110" }),
    { code: "invalid_configuration" },
  );
  assert.throws(
    () => normalizeDesiredState({ ...base, publicPathRegex: "^/.*$" }),
    { code: "invalid_configuration" },
  );
});

test("plan is safe only when tunnel name and hostname are both unused", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  const fake = new FakeCloudflare(desired);
  const plan = await planDelivery({
    client: fake,
    desired,
    accountId: ACCOUNT_ID,
    zoneId: ZONE_ID,
  });
  assert.equal(plan.ok, true);
  assert.equal(plan.tunnel.disposition, "absent");
  assert.equal(plan.dns.disposition, "absent");
  assert.deepEqual(plan.actions, [
    "create_tunnel",
    "put_exact_ingress_configuration",
    "create_proxied_cname",
    "verify_exact_ids_and_configuration",
  ]);
});

test("plan blocks unowned same-name tunnel and exact-host DNS collisions", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  const fake = new FakeCloudflare(desired);
  fake.addTunnel();
  fake.addDNSRecord();
  const plan = await planDelivery({
    client: fake,
    desired,
    accountId: ACCOUNT_ID,
    zoneId: ZONE_ID,
  });
  assert.equal(plan.ok, false);
  assert.equal(plan.tunnel.disposition, "collision");
  assert.equal(plan.dns.disposition, "collision");
  assert.equal(plan.blockers.length, 2);
});

test("apply creates exact resources, writes a private receipt, and is idempotent", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    const result = await applyFixture(fake, desired, receiptPath);
    assert.equal(result.ok, true);
    assert.equal(result.alreadyApplied, false);
    assert.equal(result.tunnel.id, TUNNEL_ID);
    assert.equal(result.tunnel.status, "inactive");
    assert.equal(result.tunnel.connectorReady, false);
    assert.deepEqual(fake.configurations.get(TUNNEL_ID), createIngressConfiguration(desired));
    assert.equal(fake.dnsRecords.get(DNS_RECORD_ID).content, `${TUNNEL_ID}.cfargotunnel.com`);

    const receipt = await readReceipt(receiptPath);
    assert.equal(receipt.state, "applied");
    assert.equal(receipt.tunnelId, TUNNEL_ID);
    assert.equal(receipt.dnsRecordId, DNS_RECORD_ID);
    assert.equal(receipt.createdTunnel, true);
    assert.equal(receipt.createdDNSRecord, true);
    assert.equal((await stat(receiptPath)).mode & 0o077, 0);
    assert.equal((await readFile(receiptPath, "utf8")).includes("token"), false);

    const mutationCount = fake.calls.filter((call) =>
      ["createTunnel", "putTunnelConfiguration", "createDNSRecord"].includes(call),
    ).length;
    const repeat = await applyDelivery({
      client: fake,
      desired,
      accountId: ACCOUNT_ID,
      zoneId: ZONE_ID,
      receiptPath,
      receipt,
      clock,
    });
    assert.equal(repeat.alreadyApplied, true);
    assert.equal(
      fake.calls.filter((call) =>
        ["createTunnel", "putTunnelConfiguration", "createDNSRecord"].includes(call),
      ).length,
      mutationCount,
    );
  });
});

test("configuration failure rolls back only the newly created tunnel", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    fake.failNext("putTunnelConfiguration", new Error("synthetic configuration failure"));
    await assert.rejects(applyFixture(fake, desired, receiptPath), /synthetic configuration failure/);
    assert.equal(fake.tunnels.size, 0);
    assert.equal(fake.dnsRecords.size, 0);
    const receipt = await readReceipt(receiptPath);
    assert.equal(receipt.state, "rolled_back");
    assert.equal(receipt.tunnelId, TUNNEL_ID);
    assert.equal(receipt.dnsRecordId, null);
    assert.equal(receipt.createdTunnel, true);
    assert.ok(fake.calls.includes("deleteTunnel"));
  });
});

test("DNS creation failure applies deny-all before deleting the exact tunnel", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    fake.failNext("createDNSRecord", new Error("synthetic DNS failure"));
    await assert.rejects(applyFixture(fake, desired, receiptPath), /synthetic DNS failure/);
    assert.equal(fake.tunnels.size, 0);
    assert.equal(fake.dnsRecords.size, 0);
    const receipt = await readReceipt(receiptPath);
    assert.equal(receipt.state, "rolled_back");
    const failedCreateIndex = fake.calls.indexOf("createDNSRecord");
    const denyAllIndex = fake.calls.indexOf("putTunnelConfiguration", failedCreateIndex + 1);
    const deleteIndex = fake.calls.indexOf("deleteTunnel", denyAllIndex + 1);
    assert.ok(failedCreateIndex >= 0);
    assert.ok(denyAllIndex > failedCreateIndex);
    assert.ok(deleteIndex > denyAllIndex);
  });
});

test("ambiguous tunnel creation outcome is retained as rollback failure", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    const createTunnel = fake.createTunnel.bind(fake);
    fake.createTunnel = async (...arguments_) => {
      await createTunnel(...arguments_);
      throw new Error("synthetic lost tunnel response");
    };
    await assert.rejects(applyFixture(fake, desired, receiptPath), {
      code: "apply_and_rollback_failed",
    });
    assert.equal(fake.tunnels.has(TUNNEL_ID), true);
    const receipt = await readReceipt(receiptPath);
    assert.equal(receipt.state, "rollback_failed");
    assert.deepEqual(receipt.rollbackErrorCodes, ["tunnel_create_outcome_ambiguous"]);
    assert.equal(receipt.tunnelId, null);
  });
});

test("ambiguous DNS creation outcome keeps the exact tunnel deny-all", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    const createDNSRecord = fake.createDNSRecord.bind(fake);
    fake.createDNSRecord = async (...arguments_) => {
      await createDNSRecord(...arguments_);
      throw new Error("synthetic lost DNS response");
    };
    await assert.rejects(applyFixture(fake, desired, receiptPath), {
      code: "apply_and_rollback_failed",
    });
    assert.equal(fake.tunnels.has(TUNNEL_ID), true);
    assert.equal(fake.dnsRecords.has(DNS_RECORD_ID), true);
    assert.deepEqual(fake.configurations.get(TUNNEL_ID), createDenyAllConfiguration(desired));
    const receipt = await readReceipt(receiptPath);
    assert.equal(receipt.state, "rollback_failed");
    assert.deepEqual(receipt.rollbackErrorCodes, ["dns_create_outcome_ambiguous"]);
    assert.equal(receipt.tunnelId, TUNNEL_ID);
    assert.equal(receipt.dnsRecordId, null);
  });
});

test("verify rejects any additional ingress rule", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    await applyFixture(fake, desired, receiptPath);
    const receipt = await readReceipt(receiptPath);
    const drifted = createIngressConfiguration(desired);
    drifted.ingress.splice(1, 0, {
      hostname: "other.cyber-lane.com",
      service: "http://127.0.0.1:9999",
    });
    fake.configurations.set(TUNNEL_ID, drifted);
    await assert.rejects(
      verifyDelivery({
        client: fake,
        desired,
        accountId: ACCOUNT_ID,
        zoneId: ZONE_ID,
        receipt,
      }),
      { code: "configuration_drift" },
    );
  });
});

test("verify rejects any path matcher wider than the two exact public APIs", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    await applyFixture(fake, desired, receiptPath);
    const receipt = await readReceipt(receiptPath);
    const drifted = createIngressConfiguration(desired);
    drifted.ingress[0].path = "^/v1/.*$";
    fake.configurations.set(TUNNEL_ID, drifted);
    await assert.rejects(
      verifyDelivery({
        client: fake,
        desired,
        accountId: ACCOUNT_ID,
        zoneId: ZONE_ID,
        receipt,
      }),
      { code: "configuration_drift" },
    );
  });
});

test("destroy requires exact hostname confirmation and a stopped connector", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    await applyFixture(fake, desired, receiptPath);
    const receipt = await readReceipt(receiptPath);
    await assert.rejects(
      destroyDelivery({
        client: fake,
        desired,
        accountId: ACCOUNT_ID,
        zoneId: ZONE_ID,
        receiptPath,
        receipt,
        confirmation: "wrong.cyber-lane.com",
        clock,
      }),
      { code: "confirmation_required" },
    );
    fake.tunnels.get(TUNNEL_ID).status = "healthy";
    await assert.rejects(
      destroyDelivery({
        client: fake,
        desired,
        accountId: ACCOUNT_ID,
        zoneId: ZONE_ID,
        receiptPath,
        receipt,
        confirmation: desired.hostname,
        clock,
      }),
      { code: "connector_still_active" },
    );
    assert.equal(fake.tunnels.has(TUNNEL_ID), true);
    assert.equal(fake.dnsRecords.has(DNS_RECORD_ID), true);
  });
});

test("destroy denies traffic then deletes only receipt-owned exact IDs", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    await applyFixture(fake, desired, receiptPath);
    const receipt = await readReceipt(receiptPath);
    fake.tunnels.get(TUNNEL_ID).status = "down";
    const start = fake.calls.length;
    const result = await destroyDelivery({
      client: fake,
      desired,
      accountId: ACCOUNT_ID,
      zoneId: ZONE_ID,
      receiptPath,
      receipt,
      confirmation: desired.hostname,
      clock,
    });
    assert.equal(result.ok, true);
    assert.equal(result.alreadyDestroyed, false);
    assert.equal(fake.tunnels.size, 0);
    assert.equal(fake.dnsRecords.size, 0);
    const destroyCalls = fake.calls.slice(start);
    assert.ok(destroyCalls.indexOf("putTunnelConfiguration") < destroyCalls.indexOf("deleteDNSRecord"));
    assert.ok(destroyCalls.indexOf("deleteDNSRecord") < destroyCalls.indexOf("deleteTunnel"));
    assert.equal((await readReceipt(receiptPath)).state, "destroyed");
  });
});

test("destroy never substitutes a new DNS ID when the receipt-owned ID is gone", async () => {
  const desired = await loadDesiredState(DESIRED_STATE_PATH);
  await withTemporaryReceipt(async (receiptPath) => {
    const fake = new FakeCloudflare(desired);
    await applyFixture(fake, desired, receiptPath);
    const receipt = await readReceipt(receiptPath);
    fake.tunnels.get(TUNNEL_ID).status = "inactive";
    fake.dnsRecords.delete(DNS_RECORD_ID);
    fake.addDNSRecord({ id: OTHER_DNS_RECORD_ID, tunnelId: OTHER_TUNNEL_ID });
    await assert.rejects(
      destroyDelivery({
        client: fake,
        desired,
        accountId: ACCOUNT_ID,
        zoneId: ZONE_ID,
        receiptPath,
        receipt,
        confirmation: desired.hostname,
        clock,
      }),
      { code: "dns_collision" },
    );
    assert.equal(fake.dnsRecords.has(OTHER_DNS_RECORD_ID), true);
    assert.equal(fake.tunnels.has(TUNNEL_ID), true);
    assert.equal((await readReceipt(receiptPath)).state, "destroy_failed");
  });
});

test("receipt paths inside the checkout are rejected", () => {
  assert.throws(
    () => validateReceiptPath(path.join(REPOSITORY_ROOT, "receipt.json"), REPOSITORY_ROOT),
    { code: "invalid_receipt_path" },
  );
});

test("Cloudflare API keeps the bearer internal and uses the fixed API origin", async () => {
  const secret = "test-secret-that-must-not-appear";
  let capturedURL;
  let capturedAuthorization;
  const client = new CloudflareAPI({
    token: secret,
    fetchImpl: async (url, options) => {
      capturedURL = url;
      capturedAuthorization = options.headers.Authorization;
      return new Response(JSON.stringify({ success: true, result: [] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    },
  });
  const result = await client.listTunnels(ACCOUNT_ID, "kaname-link-production");
  assert.deepEqual(result, []);
  assert.equal(capturedURL.origin, "https://api.cloudflare.com");
  assert.equal(capturedAuthorization, `Bearer ${secret}`);
  assert.equal(JSON.stringify(result).includes(secret), false);
});
