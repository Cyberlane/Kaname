CREATE TABLE deliveries (
    position INTEGER PRIMARY KEY AUTOINCREMENT,
    envelope_id TEXT NOT NULL UNIQUE,
    sender_device_id TEXT NOT NULL,
    recipient_device_id TEXT NOT NULL,
    sender_sequence INTEGER NOT NULL,
    payload_kind TEXT NOT NULL,
    envelope_digest TEXT NOT NULL,
    envelope_wire_base64 TEXT NOT NULL,
    recorded_at_unix_millis INTEGER NOT NULL,
    acknowledged_at_unix_millis INTEGER
);

CREATE INDEX deliveries_recipient_position
    ON deliveries(recipient_device_id, position);

CREATE TABLE enrollments (
    enrollment_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    challenge_digest TEXT NOT NULL,
    challenge_wire_base64 TEXT NOT NULL,
    receipt_wire_base64 TEXT,
    state TEXT NOT NULL DEFAULT 'pending',
    created_at_unix_millis INTEGER NOT NULL,
    updated_at_unix_millis INTEGER NOT NULL
);

CREATE TABLE push_devices (
    device_id TEXT PRIMARY KEY,
    token TEXT NOT NULL,
    environment TEXT NOT NULL CHECK(environment IN ('sandbox', 'production')),
    updated_at_unix_millis INTEGER NOT NULL,
    last_push_status INTEGER
);
