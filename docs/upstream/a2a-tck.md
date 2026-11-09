# A2A TCK: coverage and pinned upstream issues

`bin/a2a-tck` pins a2aproject/a2a-tck at
`263b9cfaf16a554bdfb166a7ba5b67716e946349`. The reports below are drafts
about **that revision**, not claims about today's upstream main. This docs
refresh does not publish them or update the runner.

## What the gate proves

`bin/ci` runs the JSON-RPC MUST-level TCK against the hosted
`concourse/conformance` agent in the default organization. `bin/a2a-tck`
boots a local disposable database, introspection stub and deterministic
responder. Its caller-side auth plugin is
`test/a2a_tck/concourse_auth_plugin.py`; the runner tree is not patched.

For both release lines, CI scopes `IO_EVENT_SELECTOR=Select` to the TCK
command. This uses io-event's portable event loop for the disposable Falcon
server and introspection stub, avoiding intermittent `io_uring_queue_init`
allocation failures on shared runners. The same pinned tests, authentication
and exact exemption still run. Production boot checks and deployed Falcon
retain their normal selector; this gate does not certify io_uring performance.

That checks the current gateway/hosted-server wire behaviour. It does not
prove native forwarding, safe inbox fallback, outbound authentication,
upstream ID mapping or direct-native discovery; none is implemented yet.
The skipped streaming prerequisites described below are also not coverage.
The app's own streaming/round-trip tests remain necessary.

## Operator live mode

`bin/a2a-tck --live <agent-base-url>` uses an already supplied
`A2A_TCK_TOKEN`. It sends real requests and requires explicit operator
authorization. Use an organization-qualified target and a token admitted
there. Never print or commit the token; this is not teammate onboarding.
Native relay will need separate upstream fixtures and end-to-end tests,
not a broader exemption.

## Issue: documented authentication is not implemented

**Title:** v1.0 TCK cannot authenticate: `A2A_AUTH_*` is documented but no client sends it

**Body:**

The TCK at `263b9cfaf16a554bdfb166a7ba5b67716e946349` cannot call a
system under test that requires a credential.

`docs/AUTHENTICATION_SETUP.md` and `docs/adrs/ADR-001-authentication-support.md`
describe `A2A_AUTH_TYPE` / `A2A_AUTH_TOKEN` (and related variables) being
injected into every transport client. At this commit that code is not in
the tree: there is no `tck/config.py`, and nothing reads `A2A_AUTH_`.

`tck/transport/jsonrpc_client.py` `JsonRpcClient.__init__` sets only
`A2A-Version`. The agent card fixture in `tests/compatibility/conftest.py`
is a bare `httpx.get` of `{sut-host}/.well-known/agent-card.json`.

A2A v1.0 §7.4 says the server MUST authenticate every incoming request
when the card declares a security requirement, and §3.1.11 requires an
authenticated `GetExtendedAgentCard`. A SUT that follows that cannot pass
MUST-level JSON-RPC tests, because the client never presents a credential.
The card fetch itself may stay unauthenticated (§7.3: clients read
`securitySchemes` before they hold a credential). The operations must not.

Please either wire the documented env vars into `httpx.Client` /
`AsyncClient` (and the gRPC metadata path) before the card fixture and
the transport clients are constructed, or drop the docs until that lands.
A pytest `-p` plugin that patches `httpx.Client` works as a caller-side
workaround and does not require editing the TCK, which is what we are
doing until this is fixed.

## Issue: CORE-SEND-003 scores a correct error as a failure

**Title:** CORE-SEND-003 does not set `expected_error`, so ContentTypeNotSupportedError fails the MUST runner

**Body:**

`tests/compatibility/core_operations/test_requirements.py`
`test_must_requirement[CORE-SEND-003-jsonrpc]` fails when the SUT does what
the requirement text and A2A v1.0 §3.1.1 require.

`tck/requirements/core_operations.py` `CORE-SEND-003` (section 3.1.1) says a
media type the agent does not support MUST result in
`ContentTypeNotSupportedError`. The sample input is a raw part with
`mediaType: application/x-unsupported-tck-type`. The requirement does not
set `expected_error`.

`_validate_response` only calls `validate_expected_error` when
`expected_error` is set. Otherwise any unsuccessful response is
`Operation failed: ...`. A SUT that returns JSON-RPC `-32005`
(`ContentTypeNotSupportedError`, §3.1.1 and §9.5) is scored as a MUST
failure. Requirements that do set `expected_error` (for example
`CORE-GET-002`) pass on the same runner.

Please set `expected_error=CONTENT_TYPE_NOT_SUPPORTED_ERROR` on
`CORE-SEND-003`, the same way the other error requirements are wired.
We are not changing the SUT to accept that media type: §3.1.1 requires
the error.

## Issue: create_working_task reuses one messageId per session

**Title:** `create_working_task` sends the same `messageId` every call, so STREAM-SUB-001/002 skip on a server that deduplicates

**Body:**

`tests/compatibility/_task_helpers.py` `_send_and_validate` builds the
message id with `tck_id(prefix)`, and `tck/requirements/base.py` `tck_id`
returns `tck-{name}-{_SESSION}`: one value for the whole run. Every
`create_working_task` call therefore sends `tck-input-required-<session>`.

A server that treats a repeated `messageId` from the same client as a
retry of the same message (A2A v1.0 §3.3.1: "Agents may utilize the
messageId to detect duplicate messages") answers the second call with the first
task. By then an earlier test has completed it, so the helper sees
`TASK_STATE_COMPLETED` and skips. STREAM-SUB-001
(`test_sse_streaming.py::test_subscribe_first_event_is_task`) and
STREAM-SUB-002 (`test_task_lifecycle.py::test_subscribe_terminates_at_terminal_state`)
never run against such a server.

Please give each prerequisite message its own id, for example
`tck_id(f"{prefix}-{uuid4()}")`, keeping the prefix the SUT routes on.

This is optional send idempotency, not an A2A guarantee. The inbox server
deduplicates; a native server may not. A reused `messageId` therefore cannot
justify automatic relay retry or inbox handover after unknown acceptance.

## CI exemption

`bin/a2a-tck` exempts a MUST failure only when the failed set is exactly the
requirement id `CORE-SEND-003`. The matcher reads that id out of the junit
testcase name (`test_must_requirement[CORE-SEND-003-jsonrpc]`) and accepts
the run only when that list is `["CORE-SEND-003"]` and nothing else failed.
A prefix, a category, or a second failure fails CI. Do not add another id
here without the same kind of upstream confirmation.
