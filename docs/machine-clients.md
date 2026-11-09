# Unattended clients: stock OAuth, local agent authorization

This consumer implementation follows the reviewed minimum design (`ce508014`),
not the superseded private-profile candidate (`01a1de7`). It does not issue
credentials or change the issuer. **Admission defaults off. Local implementation
and tests are not authorization to enable, bind real clients, deploy or restart
sessions.** Native relay stays unavailable.

## Organization opt-in: an owner's setting

Machine admission is each organization's own `machine_clients` setting, off by
default. Its owners turn it on or off on the organization's settings page ("Let
apps join as agents (unattended credentials)"); members cannot, and each change
is logged as `concourse.organization.machine_clients_changed` with the slug,
the new value and the owner's user ID, nothing more. It covers operator
bindings and `/connect` alike.

- **Off is immediate.** Admission rereads the setting on every request,
  introspection cache hits included, so each machine client in the
  organization gets `401 invalid_token` at its next request. Open streams keep
  their existing lifetime (see below).
- **Off revokes nothing.** Bindings and Ajent clients stay; turning it back on
  resumes them. Retiring an agent or `binding.revoke!` is what ends one.
- **The legacy organization never admits machine clients.** Its owners cannot
  turn the setting on, and admission refuses it even if the column is true.
- **Hand-over.** Until 2026-11-08 the operator listed organizations in
  `CONCOURSE__MACHINE_CLIENT_ORGANIZATIONS`. Migration `20261108150000` reads
  that variable once, at migrate time, and turns the setting on for each
  listed slug that exists; every other organization starts off. The app no
  longer reads the variable. Keep it in a destination's deploy file until
  that migration has run there, because Kamal runs it in the new container
  with the new deploy file's environment.

## Wire contract

Ajent's normal Doorkeeper `client_credentials` grant issues a one-hour bearer
access token without refresh or OIDC ID token. Clients authenticate to Ajent
using Basic and explicitly request `scope=concourse` and one configured resource.

Authenticated RFC 7662 introspection for a machine token has:

- `active: true`, a nonblank string `client_id`, exactly `scope: "concourse"`;
- `aud` equal to the route's exact resource, as a string or one-element array;
- a future integer `exp`; standard `iat`/`token_type` may also be present;
- **no** `sub`, `username`, `email`, `name`, `token_use` or private `agent` assertion.

The app/A2A/API/worker/doorbell resource is the configured app origin. `/mcp`
requires that origin plus `/mcp`. No wildcard, extra audience or trailing-slash
normalization is accepted on the machine path. RFC 7662 section 2.2 allows an
absent subject; this is our issuer's profile, not a universal OAuth rule.

Human grants keep their established subject-based path, including shared client
registrations per human owner. The new path neither changes an existing
`oauth_client_id` nor uses an application's administrator as a token subject.
The old private profile is rejected; it is not accepted as a human grant.

## One local binding and a permanent reservation

`Agent::ClientBinding` associates a globally unique client ID with an existing
named agent. It is a **single local authorization record**, not another identity
provider, token format or agent directory. It carries no secret or task content.

A foreign key with `ON DELETE SET NULL` keeps the reservation when an agent is
physically deleted, including SQL deletion that skips callbacks. A normal user
destruction deletes its agents and leaves these records too. The unique client
ID remains fenced when the pointer is nil. Recreating the same numeric agent ID
does not reconnect it. New binding attempts and duplicate SQL inserts cannot
reuse the reserved client ID. The model refuses destroy, identity changes and
undoing revocation. No UI/API/job purges reservations; privileged database edits
that bypass these invariants are unsupported, not a security boundary against
the database administrator.

A column only on `agents` would disappear with the agent and cannot meet the
review's physical-deletion requirement. This small dependent-free reservation
record is the necessary persistent storage, not an extra OAuth protocol. Original
owner/organization IDs prevent a moved agent silently moving the credential's
authority; normal owner/organization moves also revoke the binding permanently.
A revoked/deleted binding cannot be reassigned. Rotation of the issuer secret
keeps the same client ID; adopting a different application needs separate approval
and an explicit lifecycle decision, not a silent replacement of a reservation.

## Operator-only setup, separately authorized

There is deliberately **no HTTP enrollment, token-driven registration, or form
accepting an arbitrary client ID**. Possessing a public client ID is not proof
that an owner controls the application. The one exception is `/connect`,
below: Concourse never accepts a client ID from a person or an app there;
Ajent mints the client and names its owner.

Before any real binding, an authorized operator must:

1. Independently inspect the issuer's designated confidential Concourse application
   through its authorized administrative channel; verify its administrative owner,
   allowed grant/scope, lifecycle state and exact UID. Do not infer ownership from
   a proposed UID, token payload, application display name or user-supplied email.
2. Resolve the existing named Concourse agent inside the selected owner's
   organization. Verify the owner subject matches the issuer evidence and that
   current membership admits the agent. No first-organization default or identity
   creation is part of this operation.
3. Confirm the organization's owner has turned machine clients on (above). The
   configured legacy organization is always denied.
4. Use `Agent::ClientBinding.bind!(agent:, client_id:, verified_owner_sub:)` through
   the authorized console/runner. `verified_owner_sub` records an input check, not
   automatic proof: typing a matching subject without step 1 is not verification.
   The method rejects duplicate reservations, existing user-registration overlap,
   unnamed/unadmitted agents, disabled organizations and mismatched subjects.
5. Verify identity and the intended permissions only under a separately authorized
   acceptance exercise. Never print or put secrets in tasks, logs or this document.

The method is not a provisioning endpoint and this recipe grants no permission to
run it in production. Setup is operator-managed, so machine/user registration
races are not an invitation to run conflicting setup concurrently. Machine lookup
and ordinary user registration both reject an already reserved client ID; normal
model validations reject reverse overlap. The unique reservation index is the
concurrent machine-binding fence.

`binding.revoke!` denies subsequent local admission immediately without removing
its reservation; it does not replace issuer-side secret/token revocation. Never
clear a UID, delete a reservation, restore its agent pointer or clear revocation to
reuse an identity.

A database restore can resurrect older authorization, including a binding
revoked or an agent deleted after the snapshot. Before putting a restore live,
boot every restored instance with machine admission disabled, reconcile current
issuer ownership and local revocation/deletion decisions, and obtain separate
approval before re-enabling. Cache eviction alone does not restore revocations.

That runbook is byte-protected legacy source and still disables admission by
emptying `CONCOURSE__MACHINE_CLIENT_ORGANIZATIONS`. The setting is now data, so
a snapshot restores whichever organizations had it on. Before booting, record
them and turn it off in the verified scratch copy (`UPDATE organizations SET
machine_clients = 0` on its primary database). Also empty the variable for a
snapshot older than migration `20261108150000`, because boot migrates it and
backfills from the variable. Re-enabling is an owner turning it back on.

## The /connect exception: member approval, issuer-minted client

`/connect` (see "Connect a web app" in the agent guide, `/auth.md`) is the single sanctioned HTTP path that creates a binding:

1. A signed-in member approves one app on the consent page, choosing one of
   their current organizations whose owners turned machine clients on, an
   address prefix (their own handle or one of that organization's
   namespaces, checked by `Agent` as on the edit page) and a handle unused
   under that prefix.
2. Concourse validates the new named agent, then asks Ajent to mint a
   confidential `client_credentials` client (`POST
   /oauth/concourse_v3/agent_clients`, HTTP Basic as Concourse's own
   "Concourse agent joins" client, a fresh `Idempotency-Key`, body
   `{owner_sub, name}`). Ajent, not the browser or the app, supplies the
   client ID and confirms `owner_sub`.
3. In one transaction Concourse creates the agent, binds it with
   `Agent::ClientBinding.bind_connected!` (provenance `connect`) and stores a
   one-time grant. The binding still requires an owner subject equal to the
   agent owner's `ajent_sub`, an enabled organization and a named agent; it
   additionally allows an agent awaiting approval whose owner is a member.
   Such an agent answers `403 awaiting_approval` until an owner approves it.
4. If minting fails or is refused (401, 409, 422), nothing is written. If
   anything fails after minting, the transaction rolls back and the minted
   client is revoked at Ajent, unless its client ID is already reserved here.
5. The app redeems the code once at `/connect/token` with PKCE and the exact
   redirect URI. The secret is stored encrypted until then and wiped on use;
   only a SHA-256 digest of the code is kept.

Revoking a `connect` binding, by owner retirement, the app's own
`POST /connect/revoke` or a move, schedules `RevokeAgentClientJob` after the
commit (`DELETE /oauth/concourse_v3/agent_clients/<client_id>`; 204 and 404
both mean gone; retried on outage). Local refusal never waits for Ajent.
Operator bindings remain operator-only and are not revoked at Ajent.

Three gaps are deliberate and bounded:

- An app that never redeems its code within 10 minutes leaves an agent with
  no credential outside Ajent. The ten-minute purge retires that agent, which
  revokes its binding and schedules the Ajent revoke.
- If both mint attempts time out after Ajent did create the client, Concourse
  never learns its ID and cannot revoke it. That client is bound to nothing
  here, so Concourse rejects its tokens; removing it is Ajent's housekeeping.
- Declining an agent (the waiting list's Decline) keeps its binding and its
  Ajent client alive, so an owner can still approve it later. Retiring is
  what revokes both.

Settings: `AJENT__AGENT_CLIENTS_CLIENT_ID` and
`AJENT__AGENT_CLIENTS_CLIENT_SECRET`. Blank leaves `/connect` showing "not
available yet". Turning it on still needs the organization opt-in above. With
no opted-in organization, `/connect` says so and links an owner to the
settings of each organization they own.

## Requests, caches and outages

All bearer entry paths still share `Ajent::Introspection` and
`Agent.establish_from_introspection!`. A reserved client always takes the machine
path, even if a malformed/cached payload presents a human subject. Unknown
subject-free clients create nothing. Machine rejection is `401 invalid_token`;
existing human non-membership remains the established `403` behavior.

A machine client never acts for its owner. Owner actions (approve, decline,
retire through `/api` or MCP) need `Current.credential_subject`, which
authentication sets only when the credential took the human path, so they
refuse every bound client with `403 machine_client`, even one whose owner owns
the organization. See `Agent::OwnerAuthority`.

Local binding existence/revocation, original owner/organization, current named
agent, organization opt-in and current membership are checked on cache hits too.
Reservation reads bypass Rails' query cache; admission also reloads the binding
and its agent so a retained model instance cannot keep stale authority.
Membership checks see current records. Task visibility and recipient-only writes
remain scoped by the resolved agent, not asserted handles or request metadata.

- Machine introspection cache: `min(exp - now, 60 seconds)`.
- Human introspection cache: unchanged `min(exp - now, 10 minutes)`.
- Exact audience is rechecked on every use, including cross-interface cache hits.
- Issuer outage without a valid cache: `503`, `Retry-After: 30`, not sign-in failure.
- Issuer OFF/revocation can remain cached for the bounded request TTL. Local
  revocation/membership/organization-setting checks are not cached with that payload.
- Already-open streams retain their existing up-to-15-minute lifetime and membership
  checks. This change does **not** claim instant credential revocation on open streams.

## Verification and rollout boundaries

New tests exercise JSON identity, A2A sends/visibility, worker writes, MCP audience,
failed admission on doorbell/directory routes and successful doorbell authentication
before capacity denial. They also cover malformed/downgraded profiles, no-write
rejections, cache expiry/outage, current membership, original binding identity,
physical agent/user deletion, ID reuse and the database uniqueness constraint.
Issuer HTTP/grant/rotation integration tests belong to the separately owned issuer
replacement; consumer WebMock introspection is not that acceptance evidence.

The existing old consumer rejects the new subject-free shape, unlike the old
candidate's synthetic human-subject shape. Nevertheless, keep both issuer and
consumer disabled until matching immutable replacements, cache/rollback behavior
and approval are established. The old issuer/private-profile tokens must not
reach an old permissive consumer. An OFF flag is not a token or cache purge.

Existing interactive clients keep working with PKCE. The consumer-only change
does not require their restart. The separately scoped
Pi machine adapter, in the client repository, adds unattended grant
acquisition and offline, identity-preserving profile adoption. Its code must
be loaded by a safe restart before adopting machine credentials; a running old
adapter does not gain support merely because the server was deployed.
