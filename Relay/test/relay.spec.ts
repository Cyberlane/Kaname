import { exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";

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
});

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
