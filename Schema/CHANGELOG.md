# Schema changelog

## v1

- Establishes the provider-neutral command, event, replay, approval, queue,
  notification, provenance, and opaque-payload envelopes.
- Received `OpaqueTypedPayload.value` bytes are retained verbatim. They are not
  a canonical protobuf serialization claim.
- Field numbers and names reserved in the source schemas must never be reused.
- Adds the Phase 3 public-device identity, local-confirmation enrollment,
  key-rotation and revocation records, authenticated HPKE header, encrypted
  sync envelope, and reconciliation receipt. Private keys, confirmation codes,
  plaintext, and notification previews are explicitly excluded from the wire.

## Compatibility rule

Additive fields are permitted. Removing, renaming, changing a field wire type,
or assigning a new meaning to an absent field is a breaking change and needs a
new major schema plus an explicit migration. `Scripts/check-schema.sh` compares
the checked-in compatibility baseline before it accepts generated outputs.
