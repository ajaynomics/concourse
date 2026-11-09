module ConcourseMcp
  # Output schemas for the MCP bridge (MCP 2025-06-18 tools/outputSchema), so
  # programmatic clients such as Pi codemode scripts get typed
  # structuredContent instead of parsing JSON text. Shapes are the A2A v1.0
  # wire objects (§4.1) Concourse serializes: only fields Concourse always
  # emits are required, and objects stay open so an added field never breaks
  # a client. test/models/concourse_mcp_schemas_test.rb checks real results.
  module Schemas
    NULLABLE_STRING = { type: %w[string null] }.freeze
    OBJECT = { type: "object" }.freeze

    PART = {
      type: "object",
      description: "A2A Part (§4.1.6): one of text, raw, url or data.",
      properties: {
        text: { type: "string" },
        raw: { type: "string", description: "Base64 bytes." },
        url: { type: "string" },
        data: {},
        filename: { type: "string" },
        mediaType: { type: "string" },
        metadata: OBJECT
      }
    }.freeze

    MESSAGE = {
      type: "object",
      description: "A2A Message (§4.1.4).",
      properties: {
        messageId: { type: "string" },
        contextId: { type: "string" },
        taskId: { type: "string" },
        role: { type: "string", enum: %w[ROLE_USER ROLE_AGENT] },
        parts: { type: "array", items: PART },
        metadata: OBJECT,
        extensions: { type: "array", items: { type: "string" } },
        referenceTaskIds: { type: "array", items: { type: "string" } }
      },
      required: %w[messageId role parts]
    }.freeze

    ARTIFACT = {
      type: "object",
      description: "A2A Artifact (§4.1.7).",
      properties: {
        artifactId: { type: "string" },
        name: { type: "string" },
        description: { type: "string" },
        parts: { type: "array", items: PART },
        metadata: OBJECT,
        extensions: { type: "array", items: { type: "string" } }
      },
      required: %w[artifactId parts]
    }.freeze

    SEND_RECEIPT = {
      type: "object", additionalProperties: false,
      properties: {
        version: { type: "integer", const: 1 },
        callerInput: {
          type: "object", additionalProperties: false,
          properties: {
            cursor: { type: "string", pattern: "^[1-9][0-9]*$", not: { pattern: "[^0-9]" } },
            messageId: { type: "string", minLength: 1 }
          },
          required: %w[cursor messageId]
        }
      },
      required: %w[version callerInput]
    }.freeze

    TASK = {
      type: "object",
      description: "A2A Task (§4.1.1). metadata[\"concourse.caller\"] names the sender on a received task, metadata[\"concourse.recipient\"] the recipient on a sent one.",
      properties: {
        id: { type: "string" },
        contextId: { type: "string" },
        status: {
          type: "object",
          properties: {
            state: { type: "string", description: "TASK_STATE_SUBMITTED, _WORKING, _INPUT_REQUIRED, _AUTH_REQUIRED, _COMPLETED, _FAILED, _CANCELED or _REJECTED." },
            timestamp: { type: "string" },
            message: MESSAGE
          },
          required: %w[state]
        },
        history: { type: "array", items: MESSAGE },
        artifacts: { type: "array", items: ARTIFACT },
        metadata: { type: "object", properties: { "concourse.send_receipt" => SEND_RECEIPT } }
      },
      required: %w[id status]
    }.freeze

    AGENT = {
      type: "object",
      properties: {
        id: { type: "integer", description: "The id owner actions such as retire_agent take." },
        handle: { type: "string", description: "owner/agent, the address for send_message." },
        organization: { type: "string" },
        name: NULLABLE_STRING,
        description: NULLABLE_STRING,
        skills: { type: "array", items: OBJECT },
        harness: NULLABLE_STRING,
        projects: { type: "array", items: { type: "string" } },
        url: { type: "string", description: "The agent's A2A gateway address." },
        nativeCardUrl: { type: "string" }
      },
      required: %w[handle organization url]
    }.freeze

    PROJECT = {
      type: "object",
      properties: {
        slug: { type: "string" },
        name: { type: "string" },
        description: NULLABLE_STRING,
        agents: { type: "integer" }
      },
      required: %w[slug name]
    }.freeze

    CARD = {
      type: "object",
      description: "This agent's A2A AgentCard (§4.4.1).",
      properties: {
        name: { type: "string" },
        description: { type: "string" },
        version: { type: "string" },
        supportedInterfaces: { type: "array", items: OBJECT },
        skills: { type: "array", items: OBJECT },
        capabilities: OBJECT,
        defaultInputModes: { type: "array", items: { type: "string" } },
        defaultOutputModes: { type: "array", items: { type: "string" } }
      },
      required: %w[name]
    }.freeze

    ADMISSION = {
      type: "object",
      description: "An agent after an owner action.",
      properties: {
        id: { type: "integer" },
        address: { type: %w[string null], description: "prefix/handle; null until the agent names itself." },
        status: { type: "string", enum: %w[admitted awaiting_approval declined] }
      },
      required: %w[id address status]
    }.freeze

    PENDING_AGENT = {
      type: "object",
      properties: {
        id: { type: "integer" },
        address: { type: %w[string null], description: "prefix/handle; null until the agent names itself." },
        name: NULLABLE_STRING,
        owner: { type: "string", description: "The handle of the person whose agent it is." },
        client_id: NULLABLE_STRING,
        requested_at: { type: "string" }
      },
      required: %w[id address owner requested_at]
    }.freeze

    AGENTS = { type: "object", properties: { agents: { type: "array", items: AGENT } }, required: %w[agents] }.freeze
    PENDING_AGENTS = { type: "object", properties: { agents: { type: "array", items: PENDING_AGENT } }, required: %w[agents] }.freeze
    PROJECTS = { type: "object", properties: { projects: { type: "array", items: PROJECT } }, required: %w[projects] }.freeze
    NEXT_TASK = {
      type: "object",
      properties: { task: { anyOf: [ TASK, { type: "null" } ], description: "null when nothing is actionable before the wait ends." } },
      required: %w[task]
    }.freeze
    TASK_PAGE = {
      type: "object",
      properties: {
        tasks: { type: "array", items: TASK },
        nextPageToken: { type: "string", description: "Empty on the last page." },
        pageSize: { type: "integer" },
        totalSize: { type: "integer" }
      },
      required: %w[tasks nextPageToken]
    }.freeze
  end
end
