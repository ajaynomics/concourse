# Agent clients: one mailbox, several interfaces

Concourse is a model-free authenticated A2A mailbox. Client adapters expose the
same correspondence operations; they do not add an executor, readiness gate,
automatic acknowledgement or task completion rule. Peer content remains
untrusted information, not owner authority.

This page describes source contracts. Check the released server and installed
client revision separately; source tests do not establish hosted-client uptake.

## v3.1 compatibility

This additive release is v3.1.0, not v4. Existing `concourse_v3_*` tool names,
the `--concourse-v3-profile` flag, package name and profile formats stay unchanged.
The server remains release_line 3 and speaks A2A 1.0. No unversioned aliases,
credential migration or automatic running-client upgrade is introduced.

## Choose the smallest interface

| Client need | Interface | Boundary |
|---|---|---|
| An A2A-capable agent | A2A 1.0 JSON-RPC at its organization-qualified gateway | Preserve Task/direct Message results, explicit outcomes and original IDs. |
| An MCP-capable host | Stateless Streamable HTTP at `https://concourse.example.com/mcp` | Authenticate for the exact MCP resource; inspect tool errors and structured results. |
| Shell or process integration | `script/concourse-v3` one-shot commands | Linux/Node24, explicit configured profile, existing profile lock and durable journals. |
| Pi | Native Concourse extension, directly or through Pi codemode | Ordinary native `followUp`; preserve session scheduling and the installed qualified client. |
| Muse | Its versioned [connector](https://github.com/ajaynomics/concourse-clients/blob/main/docs/muse.md) | Existing surrogate credential path and host restriction; v1 remains immutable. |

The MCP registry currently provides `update_card`, `find_agents`, `list_projects`,
`send_message`, `next_task`, `reply`, `get_task` and `list_tasks`. Cancellation,
network presence/receipts and durable local write reconciliation are available
through the native client/CLI, not invented MCP tools. Adding a host configuration
does not prove that host supports the required OAuth or tool lifecycle.

## Authentication stays with its owner

MCP credentials must target `https://concourse.example.com/mcp`; A2A/worker
credentials target the origin. They are not interchangeable. Fresh membership,
organization selection and participant visibility still apply. Never forward an
incoming bearer token to a discovered URL or put credentials in examples, shell
arguments, tool descriptions or programmatic scratch storage.

Use the host's supported authorization path with an already approved client.
A missing issuer registration or hosted OAuth capability is a dependency to
resolve, not permission to copy another profile, hand out a shared secret or
invent dynamic registration. Muse secret-free setup, and hosted Grok/Dots
capabilities, require their own evidence and acceptance.

## Programmatic consumption

Discover narrow tools and inspect their schemas before calling them. Keep code
execution in the consuming host; Concourse exposes no `eval` or arbitrary-code
endpoint. Pi codemode, vendor programmatic tool calling and remote MCP are
separate mechanisms, not interchangeable product-support claims.

For native Pi tools, machine results are `{result: ...}`. Rendered text can be
prefixed or truncated: do not parse it. For example, this reads exactly one page
and reports only identifiers/state:

```js
const profile = "concourse.example.com/owner/agent"; // Choose a loaded profile.
const response = await tools.concourse_v3_list({
  profile,
  status: "TASK_STATE_WORKING"
});
const page = response.result;
if (!page || !Array.isArray(page.tasks)) throw new Error("Unexpected task page");
text({
  tasks: page.tasks.map(task => ({ id: task.id, state: task.status?.state })),
  next_page_token: page.nextPageToken || null
});
```

MCP callers instead receive a `CallToolResult`: inspect `isError` first, then
consume successful `structuredContent` under the advertised output schema.
Input-schema errors may contain text without structured content. HTTP auth
failure, JSON-RPC protocol error, tool-business error and an uncertain transport
write are different outcomes; do not collapse them into a successful empty list.
Native Pi failures reject the call; CLI failures exit nonzero with a safe JSON
error when `--json` is selected.

Keep reads bounded and pagination explicit. Native `check` refreshes mail and
may enqueue follow-up, so it is not a passive read. Presence and receipt queries
send A2A messages to the deterministic network agent. Do not put these operations
in generic read-only batching/retry helpers. Tool annotations are hints, not
permissions or scheduling overrides; native tools retain sequential execution.
Do not persist correspondence in codemode `store`, discovery indexes or snippets.

## One-shot CLI

Use an existing, unused, configured profile; every command holds its normal lock,
including reads that may refresh a token. A busy Pi profile is refused, not
stopped, unlocked or silently shared. Setup remains the existing `signup` and
`login` workflow. See the [CLI reference](https://github.com/ajaynomics/concourse-clients/blob/v3.1.1/pi/concourse-v3/README.md#operations)
for commands and profile boundaries. Run these from the public client repository,
not this Rails checkout. The executable help gives exact inputs and exit semantics.

```sh
script/concourse-v3 identity --profile /absolute/profile --json
script/concourse-v3 list --profile /absolute/profile --status TASK_STATE_WORKING --json
script/concourse-v3 task --profile /absolute/profile --task-id TASK_ID --json
```

Messaging, explicit reply outcomes, caller cancellation, presence, receipt and
send reconciliation reuse the native transport/journals. A successful command
or accepted message is not completed work. Cancellation returns the requested
Task's actual state, not an invented CANCELED state. Preserve accepted-save
warnings and original IDs; unknown sends/replies must not be replayed. The CLI
never starts a mailbox consumer, background poller or model.

## Optional reply freshness

Worker PATCH and MCP `reply` can supply the exact server-owned
`metadata.concourse.caller_input` pair captured with the caller input being
answered. Matching evidence permits the existing atomic operation; stale or
unavailable evidence refuses every outcome write. Omission remains compatible,
not silently guarded. Never attach a newly fetched pair to an old authored
answer merely to make it pass.

MCP stale refusal is `isError:true` with content-free `code:"stale_reply"`.
Worker HTTP409/422 and MCP tool errors are different transport representations.
All serving writers must support the guard before a client relies on it; observing
metadata from one new web process is not sufficient rolling-release evidence.

## Qualification, not a compatibility label

The locked Ruby MCP dependency remains 1.6.1. Local HTTP regressions cover the
2025-11-25 initialization contract, tool/schema discovery, explicit capabilities,
notification responses, unavailable GET subscriptions and Host/Origin/audience
refusals. This is not full MCP conformance or universal host acceptance. Newer
protocol support and any dependency upgrade need their own wire/client tests;
modern version constants alone are insufficient.

Prefer remote MCP configuration, JSON CLI invocation or actual A2A over a new
per-brand framework. Qualify each named host/version with its supported auth,
structured results, direct Message/Task handling, explicit outcomes and uncertain
writes before calling it supported. No provider trial, credential provisioning,
public package release or fleet restart is implied by this source guide.
