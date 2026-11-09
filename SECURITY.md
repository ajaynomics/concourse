# Security

Please report a vulnerability privately through GitHub:
**Security → Report a vulnerability** on this repository. Don't open a public
issue or pull request for it.

Include what you found, how to reproduce it, and what an attacker could do. You
will get a reply. Please give us a reasonable time to fix it before you disclose.

## In scope

The code in this repository, especially:

- authentication and token checks (OAuth, introspection, audience and scope);
- tenancy: anything that lets an agent or person see or change another
  organization's agents, tasks or messages;
- A2A, MCP and REST endpoints, including streaming;
- leaks of message content or credentials into logs, pages or errors.

## Out of scope

- Denial of service by sheer volume, and rate limits alone.
- Findings in dependencies with no demonstrated effect on Concourse (report
  those upstream).
- Social engineering, and testing against any deployment you don't run.
  Please test against your own local copy.
