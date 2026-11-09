# Working on Concourse

A guide for coding agents and the people driving them. Read
[README.md](README.md) and [docs/how-concourse-works.md](docs/how-concourse-works.md)
first. The [A2A v1.0 specification](https://a2a-protocol.org/latest/specification/)
is authoritative on the wire: cite its section in code and tests that depend on it.

## What it is

An A2A directory and mailbox. Agents in an organization find each other, send
requests and report explicit outcomes. Concourse stores and carries messages; it
runs no model and never plans, summarises, picks an agent or answers for one.

## Set up and test

```sh
bin/setup --skip-server       # gems and databases
bin/rails test                # Rails suite; parallel, no network
bin/rails test test/models/task_test.rb:42   # one test while you work
bin/rails test:system         # browser tests (needs Chrome)
bin/rubocop                   # style: unmodified rubocop-rails-omakase
bin/ci                        # the whole gate; CI runs exactly this
```

Tests make no outside calls: WebMock refuses every non-localhost request, so
stub a provider at the call it makes. Build test data with model constructors;
there are no fixtures or factories.

## Conventions

- Idiomatic Rails 8.2 (edge), SQLite, Falcon, Hotwire, import maps, Propshaft,
  Solid Queue/Cache/Cable, Minitest.
- Domain logic lives in models and jobs. No service layer; a thin object may
  wrap one external provider.
- CRUD controllers and REST resources. The A2A JSON-RPC endpoint dispatches on
  protocol method names because its binding requires it.
- Small objects and short methods. Comments explain why, not what.
- Live pages update through Turbo Streams over Action Cable. Don't add polling.
- Configuration is `config/<service>.yml`, read with `Concourse.config` or
  `Rails.app.creds.option`. Every setting appears in `.env.example`, and
  `test/env_example_test.rb` checks it.

## Where things live

| Path | What |
| --- | --- |
| `app/models/task.rb`, `app/models/agent.rb` | Correspondence and identity |
| `app/models/a2a/` | A2A JSON-RPC, streaming and errors |
| `app/controllers/a2a/`, `app/controllers/api/` | A2A and REST endpoints |
| `app/views/agent_guides/` | `/auth.md` and `/llms.txt`, the guides agents read |
| `JOIN-V3.md` | The setup guide served at `/join` |
| `docs/` | Human documentation |
| `bin/a2a-tck` | The A2A conformance kit run by CI |

`/llms.txt` indexes what a connecting agent needs: `/auth.md`, the OAuth
metadata, the MCP Server Card and agent cards. If you change an endpoint, a
scope or a tool, update those guides in the same pull request.

## Rules that keep it safe

- **Tenancy.** Agents, tasks and their contents belong to one organization.
  Agent queries start at `Task.visible_to(agent)`. Check visibility before any
  lookup that could reveal whether something exists (A2A §13.1).
- **Identity comes from the credential,** never from a request body or metadata.
- **Only the recipient** adds agent messages, artifacts and state; the sender
  may cancel.
- **No content in logs,** spans, events or error reports.
- **Migrations** need a test, and must be safe to run while the old code is
  still serving.
- **Secrets** are never committed, printed or put in tests. The repository has
  no credentials; don't add any.
- Advertise only what is implemented: agent cards, guides and docs must match
  the code.

Run the smallest relevant test while you work and `bin/ci` before a pull
request. See [CONTRIBUTING.md](CONTRIBUTING.md).
