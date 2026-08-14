# Workflow storage nodes

Kaname's v1 storage nodes expose logical, scoped names and opaque handles. They never expose the content-addressed store, a host path, or a raw mount path.

## Node operations

- `storage.read` with `operation: "read"` resolves one declared key. `required: false` emits a successful `missing` summary instead of inventing a value.
- `storage.read` with `operation: "list"` returns a bounded, key-ordered snapshot for the declared key or prefix. The read receipt pins that snapshot across process restart.
- `storage.write` with `operation: "write"` stores the selected input value. `fail`, `compare-and-swap`, and `replace` all commit through an optimistic revision check.
- `storage.write` with `operation: "delete-reference"` removes the current logical reference at an exact expected revision. It retains immutable version lineage for history; lifecycle deletion and object collection belong to the separate promotion/deletion stage.

Every storage operation uses a deterministic command identity. Repeating an operation after a crash returns the persisted receipt and cannot create another version, observe a newer read, or repeat deletion.

## Scope ownership

| Portable scope | Internal namespace owner | Lifetime |
|---|---|---|
| `job` | Exact run ID plus installation binding | Job/run history |
| `case` | Exact case ID plus installation binding | Related jobs in one case |
| `workflow` | Stable installation ID | Workflow revisions and jobs |

The run request pins the stable `installation_id` and optional `case_id`. Those request fields do not authorize themselves: the trusted host must separately provide the resolved storage execution authority, and any mismatch is rejected before a command or event enters the journal. A workflow that declares storage cannot start without the identities needed by its declared scopes. The portable workflow ID is not used as the long-term storage owner.

## Inspector evidence

An emitted value may include `WorkflowStorageValueMetadata`: opaque handle, product scope, logical key, immutable version ID, optimistic revision, previous-version lineage, byte count, and operation result. The disposable run projection persists only those fields. The desktop inspector presents them in a dedicated Storage group and labels content as mediated by a scoped handle.

List and optional-missing results are bounded inline JSON summaries. Individual read, write, and delete results are opaque storage references. Their bytes remain accessible only through the scoped storage service, which reauthorizes the caller and enforces a maximum copy size.

## Deliberate boundaries

- Cross-scope copying is rejected here; explicit promotion is WFP-005D.
- Job lifecycle deletion and orphan collection are WFP-005D.
- No account binding, credential, Keychain item, connector, provider, LLM, email, network call, or external effect is accessed by these nodes.
