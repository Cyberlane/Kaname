import { env, exports } from "cloudflare:workers";
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";

const authorization = { authorization: "Bearer qualification-test-token" };

async function request(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(`https://relay.test${path}`, {
    ...init,
    headers: { ...authorization, "content-type": "application/json", ...init.headers },
  });
}

async function cleanup(): Promise<void> {
  const response = await request("/v1/qualification-data", { method: "DELETE" });
  expect(response.status).toBe(200);
}

describe("Phase 3 ciphertext relay", () => {
  beforeEach(cleanup);
  afterEach(() => vi.unstubAllGlobals());

  it("requires authentication and never accepts a changed duplicate", async () => {
    const unauthenticated = await exports.default.fetch("https://relay.test/v1/deliveries?recipient=mac-authority&after=0&limit=10");
    expect(unauthenticated.status).toBe(401);

    const first = await request("/v1/envelopes", {
      method: "POST",
      body: JSON.stringify(envelope("ciphertext-one")),
    });
    expect(first.status).toBe(201);
    expect((await first.json() as { duplicate: boolean }).duplicate).toBe(false);

    const duplicate = await request("/v1/envelopes", {
      method: "POST",
      body: JSON.stringify(envelope("ciphertext-one")),
    });
    expect(duplicate.status).toBe(200);
    expect((await duplicate.json() as { duplicate: boolean }).duplicate).toBe(true);

    const changed = await request("/v1/envelopes", {
      method: "POST",
      body: JSON.stringify(envelope("changed-ciphertext")),
    });
    expect(changed.status).toBe(409);
    expect(await changed.json()).toEqual({ error: "envelope_id_reused" });
  });

  it("pulls in order, retries until acknowledgement, and cleans up", async () => {
    for (const [index, value] of ["one", "two"].entries()) {
      const response = await request("/v1/envelopes", {
        method: "POST",
        body: JSON.stringify(envelope(value, index + 1)),
      });
      expect(response.status).toBe(201);
    }
    const first = await request("/v1/deliveries?recipient=mac-authority&after=0&limit=1");
    const firstPage = await first.json() as {
      deliveries: Array<{ deliveryID: string }>;
      hasMore: boolean;
    };
    expect(firstPage.deliveries).toHaveLength(1);
    expect(firstPage.hasMore).toBe(true);

    const retry = await request("/v1/deliveries?recipient=mac-authority&after=0&limit=1");
    expect(await retry.json()).toEqual(firstPage);

    const acknowledgement = await request(`/v1/deliveries/${firstPage.deliveries[0].deliveryID}/ack`, {
      method: "POST",
      body: JSON.stringify({ recipientDeviceID: "mac-authority" }),
    });
    expect(acknowledgement.status).toBe(204);

    const cleaned = await request("/v1/qualification-data", { method: "DELETE" });
    expect((await cleaned.json() as { deletedRows: number }).deletedRows).toBeGreaterThanOrEqual(2);
  });

  it("records an enrollment receipt once and removes push routing metadata", async () => {
    const challenge = btoa("public-enrollment-challenge");
    const enrollment = await request("/v1/enrollments", {
      method: "POST",
      body: JSON.stringify({
        enrollmentID: "enrollment-1",
        deviceID: "iphone-justin",
        challengeWireBase64: challenge,
      }),
    });
    expect(enrollment.status).toBe(201);

    const receipt = await request("/v1/enrollments/enrollment-1/receipt", {
      method: "POST",
      body: JSON.stringify({ state: "active", receiptWireBase64: btoa("active-receipt") }),
    });
    expect(receipt.status).toBe(204);
    const stored = await request("/v1/enrollments/enrollment-1");
    expect(await stored.json()).toMatchObject({ state: "active", receiptWireBase64: btoa("active-receipt") });

    const push = await request("/v1/devices/iphone-justin/push-token", {
      method: "PUT",
      body: JSON.stringify({ token: "ab".repeat(32), environment: "sandbox" }),
    });
    expect(push.status).toBe(204);
    expect((await request("/v1/devices/iphone-justin/push-token", { method: "DELETE" })).status).toBe(204);
  });

  it("sends only the safe APNs hint and records the provider result", async () => {
    const bindings = {
      DB: env.DB,
      RELAY_BEARER_TOKEN: env.RELAY_BEARER_TOKEN,
      APNS_KEY_P8: await ephemeralAPNsPrivateKey(),
      APNS_KEY_ID: "QUALIFY123",
      APNS_TEAM_ID: "TEAM123456",
      APNS_TOPIC: "com.cyberlane.kaname.iphoneprototype",
    };
    let observed: Request | undefined;
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      observed = new Request(input, init);
      return new Response(null, { status: 200 });
    }));

    let ctx = createExecutionContext();
    const registered = await worker.fetch(
      incomingRequest("/v1/devices/iphone-justin/push-token", {
        method: "PUT",
        body: JSON.stringify({ token: "ab".repeat(32), environment: "sandbox" }),
      }),
      bindings,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    expect(registered.status).toBe(204);

    ctx = createExecutionContext();
    const sent = await worker.fetch(
      incomingRequest("/v1/envelopes", {
        method: "POST",
        body: JSON.stringify({
          ...envelope("encrypted-work-content"),
          senderDeviceID: "mac-authority",
          recipientDeviceID: "iphone-justin",
        }),
      }),
      bindings,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    expect(sent.status).toBe(201);

    const apnsRequest = expectDefined(observed);
    expect(apnsRequest.url).toBe(`https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
    expect(apnsRequest.method).toBe("POST");
    expect(apnsRequest.headers.get("apns-topic")).toBe("com.cyberlane.kaname.iphoneprototype");
    expect(apnsRequest.headers.get("apns-push-type")).toBe("alert");
    expect(apnsRequest.headers.get("apns-priority")).toBe("10");
    expect(await apnsRequest.json()).toEqual({
      aps: {
        alert: {
          title: "Kaname",
          body: "Open Kaname to view this update.",
        },
        sound: "default",
        "content-available": 1,
      },
    });

    const authorization = expectDefined(apnsRequest.headers.get("authorization"));
    const token = expectDefined(authorization.match(/^bearer (.+)$/)?.[1]);
    const [header, claims, signature] = token.split(".");
    expect(JSON.parse(decodeBase64URL(header))).toEqual({ alg: "ES256", kid: "QUALIFY123" });
    expect(JSON.parse(decodeBase64URL(claims))).toMatchObject({ iss: "TEAM123456" });
    expect(signature.length).toBeGreaterThan(40);

    const stored = await env.DB.prepare(
      "SELECT last_push_status FROM push_devices WHERE device_id = ?1",
    ).bind("iphone-justin").first<{ last_push_status: number }>();
    expect(stored?.last_push_status).toBe(200);
  });
});

const IncomingRequest = Request<unknown, IncomingRequestCfProperties>;

function incomingRequest(path: string, init: RequestInit): Request {
  return new IncomingRequest(`https://relay.test${path}`, {
    ...init,
    headers: { ...authorization, "content-type": "application/json", ...init.headers },
  });
}

async function ephemeralAPNsPrivateKey(): Promise<string> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const bytes = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const encoded = btoa(String.fromCharCode(...bytes));
  const lines = encoded.match(/.{1,64}/g) ?? [];
  return `-----BEGIN PRIVATE KEY-----\n${lines.join("\n")}\n-----END PRIVATE KEY-----`;
}

function decodeBase64URL(value: string): string {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return atob(padded);
}

function expectDefined<T>(value: T | null | undefined): T {
  if (value === null || value === undefined) {
    throw new Error("Expected value to be defined");
  }
  return value;
}

function envelope(value: string, sequence = 1): Record<string, unknown> {
  return {
    envelopeID: `envelope-${sequence}`,
    senderDeviceID: "iphone-justin",
    recipientDeviceID: "mac-authority",
    senderSequence: sequence,
    payloadKind: "queue.enqueue",
    envelopeWireBase64: btoa(value),
  };
}
