const MAXIMUM_REQUEST_BYTES = 128 * 1024;
const MAXIMUM_ENVELOPE_BYTES = 80 * 1024;
const MAXIMUM_ENROLLMENT_BYTES = 16 * 1024;
const MAXIMUM_PAGE_SIZE = 100;
const IDENTIFIER = /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$/;

type RelayBindings = Env & {
  RELAY_BEARER_TOKEN: string;
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
};

type SendEnvelopeRequest = {
  envelopeID: string;
  senderDeviceID: string;
  recipientDeviceID: string;
  senderSequence: number;
  payloadKind: string;
  envelopeWireBase64: string;
};

type DeliveryRow = {
  position: number;
  envelope_id: string;
  recipient_device_id: string;
  envelope_wire_base64: string;
  envelope_digest: string;
  recorded_at_unix_millis: number;
};

type PushDeviceRow = {
  token: string;
  environment: "sandbox" | "production";
};

class RelayError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return new Response(null, { status: 204, headers: noStoreHeaders() });
      }
      await authenticate(request, env.RELAY_BEARER_TOKEN);

      if (request.method === "POST" && url.pathname === "/v1/envelopes") {
        return await sendEnvelope(request, env, ctx);
      }
      if (request.method === "GET" && url.pathname === "/v1/deliveries") {
        return await pullDeliveries(url, env.DB);
      }
      const acknowledgement = url.pathname.match(/^\/v1\/deliveries\/(relay-delivery-[1-9][0-9]*)\/ack$/);
      if (request.method === "POST" && acknowledgement) {
        return await acknowledgeDelivery(request, env.DB, acknowledgement[1]);
      }
      if (request.method === "POST" && url.pathname === "/v1/enrollments") {
        return await createEnrollment(request, env.DB);
      }
      const enrollment = url.pathname.match(/^\/v1\/enrollments\/([a-zA-Z0-9][a-zA-Z0-9._:-]{0,127})$/);
      if (request.method === "GET" && enrollment) {
        return await getEnrollment(env.DB, enrollment[1]);
      }
      const enrollmentReceipt = url.pathname.match(/^\/v1\/enrollments\/([a-zA-Z0-9][a-zA-Z0-9._:-]{0,127})\/receipt$/);
      if (request.method === "POST" && enrollmentReceipt) {
        return await recordEnrollmentReceipt(request, env.DB, enrollmentReceipt[1]);
      }
      const pushToken = url.pathname.match(/^\/v1\/devices\/([a-zA-Z0-9][a-zA-Z0-9._:-]{0,127})\/push-token$/);
      if (request.method === "PUT" && pushToken) {
        return await registerPushToken(request, env.DB, pushToken[1]);
      }
      if (request.method === "DELETE" && pushToken) {
        return await deletePushToken(env.DB, pushToken[1]);
      }
      if (request.method === "DELETE" && url.pathname === "/v1/qualification-data") {
        return await deleteQualificationData(env.DB);
      }
      throw new RelayError(404, "not_found");
    } catch (error) {
      if (error instanceof RelayError) {
        return json({ error: error.code }, error.status);
      }
      console.error("relay_request_failed", { path: new URL(request.url).pathname });
      return json({ error: "internal_error" }, 500);
    }
  },
} satisfies ExportedHandler<RelayBindings>;

async function sendEnvelope(
  request: Request,
  env: RelayBindings,
  ctx: ExecutionContext,
): Promise<Response> {
  const body = await readJSON<SendEnvelopeRequest>(request);
  requireIdentifier(body.envelopeID);
  requireIdentifier(body.senderDeviceID);
  requireIdentifier(body.recipientDeviceID);
  requireIdentifier(body.payloadKind);
  if (body.senderDeviceID === body.recipientDeviceID) {
    throw new RelayError(400, "invalid_envelope");
  }
  if (!Number.isSafeInteger(body.senderSequence) || body.senderSequence < 1) {
    throw new RelayError(400, "invalid_envelope");
  }
  const envelopeBytes = decodeBase64(body.envelopeWireBase64, MAXIMUM_ENVELOPE_BYTES);
  const canonicalWire = encodeBase64(envelopeBytes);
  const digest = await sha256Base64URL(envelopeBytes);
  const now = Date.now();
  const inserted = await env.DB.prepare(
    `INSERT INTO deliveries (
      envelope_id, sender_device_id, recipient_device_id, sender_sequence,
      payload_kind, envelope_digest, envelope_wire_base64, recorded_at_unix_millis
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    ON CONFLICT(envelope_id) DO NOTHING`,
  )
    .bind(
      body.envelopeID,
      body.senderDeviceID,
      body.recipientDeviceID,
      body.senderSequence,
      body.payloadKind,
      digest,
      canonicalWire,
      now,
    )
    .run();

  const stored = await env.DB.prepare(
    `SELECT position, envelope_id, recipient_device_id, envelope_wire_base64,
            envelope_digest, recorded_at_unix_millis
       FROM deliveries WHERE envelope_id = ?1`,
  )
    .bind(body.envelopeID)
    .first<DeliveryRow>();
  if (!stored) throw new RelayError(500, "storage_failure");

  const duplicate = (inserted.meta.changes ?? 0) === 0;
  if (
    duplicate &&
    (stored.envelope_digest !== digest || stored.envelope_wire_base64 !== canonicalWire)
  ) {
    throw new RelayError(409, "envelope_id_reused");
  }

  if (!duplicate) {
    ctx.waitUntil(sendPushHint(env, body.recipientDeviceID));
  }
  return json(
    {
      deliveryID: deliveryID(stored.position),
      relayPosition: stored.position,
      duplicate,
      recordedAtUnixMillis: stored.recorded_at_unix_millis,
    },
    duplicate ? 200 : 201,
  );
}

async function pullDeliveries(url: URL, db: D1Database): Promise<Response> {
  const recipient = url.searchParams.get("recipient") ?? "";
  requireIdentifier(recipient);
  const after = parseUnsignedInteger(url.searchParams.get("after") ?? "0", "invalid_cursor");
  const limit = parseUnsignedInteger(url.searchParams.get("limit") ?? "50", "invalid_page_size");
  if (limit < 1 || limit > MAXIMUM_PAGE_SIZE) {
    throw new RelayError(400, "invalid_page_size");
  }
  const maximum = await db.prepare("SELECT COALESCE(MAX(position), 0) AS maximum FROM deliveries")
    .first<{ maximum: number }>();
  if (after > (maximum?.maximum ?? 0)) {
    throw new RelayError(400, "invalid_cursor");
  }
  const result = await db.prepare(
    `SELECT position, envelope_id, recipient_device_id, envelope_wire_base64,
            envelope_digest, recorded_at_unix_millis
       FROM deliveries
      WHERE recipient_device_id = ?1 AND position > ?2 AND acknowledged_at_unix_millis IS NULL
      ORDER BY position ASC LIMIT ?3`,
  )
    .bind(recipient, after, limit + 1)
    .all<DeliveryRow>();
  const rows = result.results;
  const selected = rows.slice(0, limit);
  return json({
    deliveries: selected.map((row) => ({
      deliveryID: deliveryID(row.position),
      relayPosition: row.position,
      recipientDeviceID: row.recipient_device_id,
      envelopeWireBase64: row.envelope_wire_base64,
    })),
    nextPosition: selected.at(-1)?.position ?? after,
    hasMore: rows.length > selected.length,
  });
}

async function acknowledgeDelivery(
  request: Request,
  db: D1Database,
  identifier: string,
): Promise<Response> {
  const body = await readJSON<{ recipientDeviceID: string }>(request);
  requireIdentifier(body.recipientDeviceID);
  const position = Number(identifier.slice("relay-delivery-".length));
  const stored = await db.prepare(
    "SELECT recipient_device_id FROM deliveries WHERE position = ?1",
  )
    .bind(position)
    .first<{ recipient_device_id: string }>();
  if (!stored) throw new RelayError(404, "delivery_not_found");
  if (stored.recipient_device_id !== body.recipientDeviceID) {
    throw new RelayError(403, "recipient_mismatch");
  }
  await db.prepare(
    `UPDATE deliveries SET acknowledged_at_unix_millis = COALESCE(acknowledged_at_unix_millis, ?1)
      WHERE position = ?2`,
  )
    .bind(Date.now(), position)
    .run();
  return new Response(null, { status: 204, headers: noStoreHeaders() });
}

async function createEnrollment(request: Request, db: D1Database): Promise<Response> {
  const body = await readJSON<{
    enrollmentID: string;
    deviceID: string;
    challengeWireBase64: string;
  }>(request);
  requireIdentifier(body.enrollmentID);
  requireIdentifier(body.deviceID);
  const wire = decodeBase64(body.challengeWireBase64, MAXIMUM_ENROLLMENT_BYTES);
  const canonicalWire = encodeBase64(wire);
  const digest = await sha256Base64URL(wire);
  const now = Date.now();
  const inserted = await db.prepare(
    `INSERT INTO enrollments (
      enrollment_id, device_id, challenge_digest, challenge_wire_base64,
      created_at_unix_millis, updated_at_unix_millis
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?5)
    ON CONFLICT(enrollment_id) DO NOTHING`,
  )
    .bind(body.enrollmentID, body.deviceID, digest, canonicalWire, now)
    .run();
  const stored = await db.prepare(
    `SELECT device_id, challenge_digest, challenge_wire_base64
       FROM enrollments WHERE enrollment_id = ?1`,
  )
    .bind(body.enrollmentID)
    .first<{ device_id: string; challenge_digest: string; challenge_wire_base64: string }>();
  if (!stored) throw new RelayError(500, "storage_failure");
  const duplicate = (inserted.meta.changes ?? 0) === 0;
  if (
    stored.device_id !== body.deviceID ||
    stored.challenge_digest !== digest ||
    stored.challenge_wire_base64 !== canonicalWire
  ) {
    throw new RelayError(409, "enrollment_id_reused");
  }
  return json({ enrollmentID: body.enrollmentID, duplicate }, duplicate ? 200 : 201);
}

async function getEnrollment(db: D1Database, enrollmentID: string): Promise<Response> {
  const stored = await db.prepare(
    `SELECT enrollment_id, device_id, challenge_wire_base64, receipt_wire_base64, state,
            created_at_unix_millis, updated_at_unix_millis
       FROM enrollments WHERE enrollment_id = ?1`,
  )
    .bind(enrollmentID)
    .first<Record<string, string | number | null>>();
  if (!stored) throw new RelayError(404, "enrollment_not_found");
  return json({
    enrollmentID: stored.enrollment_id,
    deviceID: stored.device_id,
    challengeWireBase64: stored.challenge_wire_base64,
    receiptWireBase64: stored.receipt_wire_base64,
    state: stored.state,
    createdAtUnixMillis: stored.created_at_unix_millis,
    updatedAtUnixMillis: stored.updated_at_unix_millis,
  });
}

async function recordEnrollmentReceipt(
  request: Request,
  db: D1Database,
  enrollmentID: string,
): Promise<Response> {
  const body = await readJSON<{ state: string; receiptWireBase64: string }>(request);
  if (!["active", "rejected", "revoked"].includes(body.state)) {
    throw new RelayError(400, "invalid_enrollment_state");
  }
  const receipt = encodeBase64(decodeBase64(body.receiptWireBase64, MAXIMUM_ENROLLMENT_BYTES));
  const result = await db.prepare(
    `UPDATE enrollments
        SET receipt_wire_base64 = ?1, state = ?2, updated_at_unix_millis = ?3
      WHERE enrollment_id = ?4 AND receipt_wire_base64 IS NULL`,
  )
    .bind(receipt, body.state, Date.now(), enrollmentID)
    .run();
  if ((result.meta.changes ?? 0) === 0) {
    const existing = await db.prepare(
      "SELECT receipt_wire_base64, state FROM enrollments WHERE enrollment_id = ?1",
    )
      .bind(enrollmentID)
      .first<{ receipt_wire_base64: string | null; state: string }>();
    if (!existing) throw new RelayError(404, "enrollment_not_found");
    if (existing.receipt_wire_base64 !== receipt || existing.state !== body.state) {
      throw new RelayError(409, "enrollment_receipt_already_recorded");
    }
  }
  return new Response(null, { status: 204, headers: noStoreHeaders() });
}

async function registerPushToken(
  request: Request,
  db: D1Database,
  deviceID: string,
): Promise<Response> {
  const body = await readJSON<{ token: string; environment: string }>(request);
  if (!/^[a-fA-F0-9]{64,256}$/.test(body.token)) {
    throw new RelayError(400, "invalid_push_token");
  }
  if (body.environment !== "sandbox" && body.environment !== "production") {
    throw new RelayError(400, "invalid_push_environment");
  }
  await db.prepare(
    `INSERT INTO push_devices (device_id, token, environment, updated_at_unix_millis)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(device_id) DO UPDATE SET
       token = excluded.token,
       environment = excluded.environment,
       updated_at_unix_millis = excluded.updated_at_unix_millis,
       last_push_status = NULL`,
  )
    .bind(deviceID, body.token.toLowerCase(), body.environment, Date.now())
    .run();
  return new Response(null, { status: 204, headers: noStoreHeaders() });
}

async function deletePushToken(db: D1Database, deviceID: string): Promise<Response> {
  await db.prepare("DELETE FROM push_devices WHERE device_id = ?1").bind(deviceID).run();
  return new Response(null, { status: 204, headers: noStoreHeaders() });
}

async function deleteQualificationData(db: D1Database): Promise<Response> {
  const result = await db.batch([
    db.prepare("DELETE FROM deliveries"),
    db.prepare("DELETE FROM enrollments"),
    db.prepare("DELETE FROM push_devices"),
  ]);
  return json({ deletedRows: result.reduce((count, entry) => count + (entry.meta.changes ?? 0), 0) });
}

async function sendPushHint(env: RelayBindings, recipientDeviceID: string): Promise<void> {
  const configured =
    env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC;
  if (!configured) return;
  const device = await env.DB.prepare(
    "SELECT token, environment FROM push_devices WHERE device_id = ?1",
  )
    .bind(recipientDeviceID)
    .first<PushDeviceRow>();
  if (!device) return;

  let status = 0;
  try {
    const authorization = await createAPNsAuthorization(
      env.APNS_KEY_P8!,
      env.APNS_KEY_ID!,
      env.APNS_TEAM_ID!,
    );
    const host = device.environment === "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${device.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${authorization}`,
        "apns-topic": env.APNS_TOPIC!,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: {
          alert: {
            title: "Kaname",
            body: "Open Kaname to view this update.",
          },
          sound: "default",
          "content-available": 1,
        },
      }),
    });
    status = response.status;
  } catch {
    status = 599;
  }
  await env.DB.prepare(
    "UPDATE push_devices SET last_push_status = ?1 WHERE device_id = ?2",
  )
    .bind(status, recipientDeviceID)
    .run();
}

async function createAPNsAuthorization(
  pem: string,
  keyID: string,
  teamID: string,
): Promise<string> {
  const header = base64URLJSON({ alg: "ES256", kid: keyID });
  const claims = base64URLJSON({ iss: teamID, iat: Math.floor(Date.now() / 1000) });
  const signingInput = `${header}.${claims}`;
  const keyBytes = pemToBytes(pem);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${encodeBase64URL(new Uint8Array(signature))}`;
}

async function authenticate(request: Request, expectedToken: string): Promise<void> {
  const authorization = request.headers.get("authorization") ?? "";
  const supplied = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  if (!expectedToken || !supplied) throw new RelayError(401, "unauthorized");
  const [expectedDigest, suppliedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(expectedToken)),
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(supplied)),
  ]);
  const expected = new Uint8Array(expectedDigest);
  const candidate = new Uint8Array(suppliedDigest);
  let different = expected.length ^ candidate.length;
  for (let index = 0; index < expected.length; index += 1) {
    different |= expected[index] ^ candidate[index];
  }
  if (different !== 0) throw new RelayError(401, "unauthorized");
}

async function readJSON<T>(request: Request): Promise<T> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAXIMUM_REQUEST_BYTES) {
    throw new RelayError(413, "request_too_large");
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.length === 0 || bytes.length > MAXIMUM_REQUEST_BYTES) {
    throw new RelayError(bytes.length === 0 ? 400 : 413, bytes.length === 0 ? "invalid_json" : "request_too_large");
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes)) as T;
  } catch {
    throw new RelayError(400, "invalid_json");
  }
}

function requireIdentifier(value: unknown): asserts value is string {
  if (typeof value !== "string" || !IDENTIFIER.test(value)) {
    throw new RelayError(400, "invalid_identifier");
  }
}

function parseUnsignedInteger(value: string, code: string): number {
  if (!/^(0|[1-9][0-9]*)$/.test(value)) throw new RelayError(400, code);
  const number = Number(value);
  if (!Number.isSafeInteger(number)) throw new RelayError(400, code);
  return number;
}

function decodeBase64(value: unknown, maximumBytes: number): Uint8Array {
  if (typeof value !== "string" || value.length === 0 || value.length > maximumBytes * 2) {
    throw new RelayError(400, "invalid_base64");
  }
  try {
    const binary = atob(value);
    if (binary.length === 0 || binary.length > maximumBytes) {
      throw new RelayError(413, "payload_too_large");
    }
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    if (encodeBase64(bytes) !== value) throw new RelayError(400, "invalid_base64");
    return bytes;
  } catch (error) {
    if (error instanceof RelayError) throw error;
    throw new RelayError(400, "invalid_base64");
  }
}

function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function sha256Base64URL(bytes: Uint8Array): Promise<string> {
  return encodeBase64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
}

function base64URLJSON(value: unknown): string {
  return encodeBase64URL(new TextEncoder().encode(JSON.stringify(value)));
}

function encodeBase64URL(bytes: Uint8Array): string {
  return encodeBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function pemToBytes(pem: string): Uint8Array {
  const base64 = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  return decodeBase64(base64, 8 * 1024);
}

function deliveryID(position: number): string {
  return `relay-delivery-${position}`;
}

function noStoreHeaders(): HeadersInit {
  return { "cache-control": "no-store" };
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { ...noStoreHeaders(), "content-type": "application/json; charset=utf-8" },
  });
}
