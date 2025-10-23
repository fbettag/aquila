# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Aquila is an Elixir library for orchestrating OpenAI-compatible Responses and Chat Completions APIs. It provides unified streaming, tool calling, audio transcription, and deterministic testing via cassette-backed fixtures.

## Common Commands

### Development
```bash
mix deps.get              # Fetch dependencies
mix compile               # Compile the library
mix quality               # Run format + coveralls + credo (requires ≥82% coverage)
mix format                # Format code
mix credo                 # Run static analysis
```

### Testing
```bash
mix test                                              # Run all tests (uses cassettes)
mix test --only live                                  # Run only live API tests (requires OPENAI_API_KEY)
mix test --exclude live                               # Skip live API tests
mix test test/path/to/specific_test.exs              # Run specific test file
mix test test/path/to/specific_test.exs:42           # Run specific test at line 42
mix coveralls                                         # Run tests with coverage report
mix coveralls.html                                    # Generate HTML coverage report

# Re-record cassettes when prompts change
OPENAI_API_KEY=sk-... mix test test/integration/responses_retrieval_test.exs
```

### Documentation
```bash
mix docs                  # Generate HTML docs in _build/dev/lib/aquila/doc
```

## High-Level Architecture

### Core Request Flow

1. **Entry Point** (`lib/aquila.ex`): Public API (`ask/2`, `stream/2`, `retrieve_response/2`, `delete_response/2`, `transcribe_audio/2`, `deep_research_*`)
2. **Orchestration** (`lib/aquila/engine.ex`): Normalizes prompts into `Aquila.Message` structs, manages streaming loop, executes tools, builds request/response bodies
3. **Transport Layer** (`lib/aquila/transport/`): HTTP adapters that implement the `Aquila.Transport` behavior for POST/GET/DELETE and SSE streaming
4. **Streaming Output** (`lib/aquila/sink.ex`): Delivers chunks to processes, callbacks, or collectors

### Key Modules

- **`Aquila.Engine`**: Internal orchestration loop. Converts inputs to messages, streams via transport, tracks tool calls, executes callbacks, and hydrates `%Aquila.Response{}`. Supports both Responses API and Chat Completions (default).
- **`Aquila.Message`**: Represents user/assistant/system/function messages. Normalized from strings or lists via `Message.normalize/2`.
- **`Aquila.Tool`**: Wraps callable functions with JSON Schema parameters. Engine decodes args, invokes callbacks, and feeds output back to model.
- **`Aquila.Sink`**: Protocol for streaming destinations. Built-in implementations: `pid/2` (send tuples to process), `fun/1` (callback), `collector/1` (test assertions).
- **`Aquila.Transport.OpenAI`**: Production HTTP client using `Req`. Parses SSE streams and normalizes events to engine format.
- **`Aquila.Transport.Record`**: Wraps inner transport, records cassettes on first run, replays locally on subsequent runs. Verifies prompt integrity by comparing normalized request bodies.
- **`Aquila.Transport.Replay`**: Used by Record to replay SSE streams from `.sse.jsonl` files.
- **`Aquila.Endpoint`**: Determines whether to use `:responses` or `:chat` based on model name and configuration.

### Tool Calling Flow

1. Model returns tool_call events with `id`, `name`, and `args_fragment`
2. Engine tracks pending calls, accumulating args fragments until `tool_call_end` event
3. When `finish_reason` indicates `requires_action`, engine executes ready callbacks
4. Callbacks receive `(args, context)` or just `(args)` and return:
   - Plain value (string/map)
   - `{:ok, value}` or `{:error, reason}`
   - `{:ok | :error, value, context_patch}` to update shared state
   - Ecto changesets are auto-formatted into readable error messages
5. For Responses API: tool outputs sent via `previous_response_id` and `tool_outputs` in next request
6. For Chat Completions: function messages appended to conversation
7. Loop repeats until `status` is `:completed` or `:succeeded`

### Cassette Recording & Replay

Tests use `aquila_cassette/3` macro (from `Aquila.Cassette`) to assign cassette names. Files live under `test/support/fixtures/aquila_cassettes/`:
- `<name>-<index>.meta.json` – request metadata (URL, headers, normalized body, HTTP method)
- `<name>-<index>.sse.jsonl` – line-delimited SSE events for streaming
- `<name>-<index>.json` – buffered JSON response for non-streaming calls

**Recording**: When cassette missing or body mismatches, `Transport.Record` delegates to `Transport.OpenAI`, captures response, and writes files (Authorization headers redacted).

**Replay**: `Transport.Replay` reads `.sse.jsonl` line by line, emits events to engine callback.

**Verification**: On every test run, normalized request body is compared to stored copy. Mismatch raises with instructions to delete stale files.

### Prompt Normalization

`Aquila.Transport.Body.normalize_body/1` ensures cassette stability:
- Strips `metadata` field
- Normalizes messages: trims whitespace, sorts object keys, canonicalizes content arrays
- For streaming: removes `stream_options` and `stream: true`
- Sorts tool definitions by name
- Result is hashed and stored in `.meta.json` to detect drift

### Endpoints: Responses vs Chat Completions

`Aquila.Endpoint.choose/1` selects API based on model name patterns and explicit `:endpoint` option:
- Deep Research models (e.g., `openai/o3-deep-research-2025-06-26`) → `:responses`
- Explicit `endpoint: :chat` or `endpoint: :responses` in options
- Otherwise, defaults to `:chat` endpoint

**Responses API** (`/responses`):
- Tools use `previous_response_id` + `tool_outputs` for continuation
- Supports `store: true` for server-side persistence
- `instructions` field for system prompt
- Input/output use content parts: `input_text`, `output_text`

**Chat Completions** (`/chat/completions`):
- Tools append function messages to conversation
- System prompt as first message with `role: "system"`
- Standard message array format

## Testing Guidelines

### Cassette-Based Tests

Most tests use prerecorded cassettes. When prompts, instructions, or tool definitions change:

1. Delete stale cassette files (error message lists them)
2. Set `OPENAI_API_KEY=sk-...` in environment
3. Rerun affected test to record fresh cassettes
4. Commit new/updated cassette files

### LiveView Tests

Use `Phoenix.LiveViewTest.render_async/1` to wait for async tasks:

```elixir
aquila_cassette "chat_live.responds" do
  {:ok, view, _html} = live(conn, ~p"/chat")
  view |> form("#chat-form", message: %{content: "Hi"}) |> render_submit()
  assert render_async(view) =~ "Hello there!"
end
```

### Live API Tests

Tests tagged with `:live` hit real OpenAI API:
- Require `OPENAI_API_KEY` environment variable
- Run with `mix test --only live`
- Skip with `mix test --exclude live` (default when key missing)
- Consume API quota and network access

### Coverage Requirements

`mix quality` enforces ≥82% test coverage via ExCoveralls. Add tests when introducing new behavior.

## Important Patterns

### Streaming Events

Engine handles these normalized event types (from `Aquila.Transport` implementations):
- `:delta` – text chunk with `:content` field
- `:message` – full message (converted to delta)
- `:response_ref` – response ID from Responses API
- `:usage` – token usage stats
- `:tool_call` – tool invocation with `:id`, `:name`, `:args_fragment`
- `:tool_call_end` – finalizes tool call, triggers execution
- `:done` – stream complete with `:status` (`:completed`, `:succeeded`, `:requires_action`)
- `:event` – generic event payload forwarded to sink
- `:error` – transport/API error

### Sink Notifications

Sinks receive these tuples (with stream ref):
- `{:aquila_chunk, chunk, ref}` – text delta
- `{:aquila_done, text, meta, ref}` – stream complete
- `{:aquila_event, payload, ref}` – custom event
- `{:aquila_error, error, ref}` – failure

Additional prefixed versions exist for LiveView (`aquila_stream_*`) and Deep Research (`aquila_stream_research_event`).

### Telemetry Events

- `[:aquila, :stream, :start]` – measurements: `system_time`, metadata: `endpoint`, `model`, `stream?`
- `[:aquila, :stream, :chunk]` – measurements: `size`, metadata: `endpoint`, `model`, `stream?`
- `[:aquila, :stream, :stop]` – measurements: `duration`, metadata: `endpoint`, `model`, `stream?`, `status`
- `[:aquila, :tool, :invoke]` – measurements: `duration`, metadata: `name`, `model`

### Configuration Keys

Runtime config in `config/runtime.exs`:
```elixir
config :aquila, :openai,
  api_key: System.fetch_env!("OPENAI_API_KEY"),
  base_url: "https://api.openai.com/v1",
  default_model: "gpt-4o-mini",
  transcription_model: "gpt-4o-mini-transcribe",
  request_timeout: 30_000
```

Test config in `config/test.exs`:
```elixir
config :aquila, transport: Aquila.Transport.Record
config :aquila, :recorder,
  path: "test/support/fixtures/aquila_cassettes",
  transport: Aquila.Transport.OpenAI
```

Optional runtime transport override:
```elixir
config :aquila, :transport, Aquila.Transport.OpenAI  # Default
```

## Code Style

- Follow Elixir formatter defaults (2-space indentation, snake_case files)
- Use `mix format` before committing
- Module names are PascalCase, files are snake_case
- Private helpers use `defp`
- Comments should explain non-obvious logic, not syntax
- Keep functions focused and testable

## Commit Guidelines

- Imperative mood subjects (e.g., "Add retrieval helper", "Fix streaming timeout")
- Subject under ~72 characters
- Reference issues in body when applicable
- Group mechanical changes (formatting, deps) separately from functional work
- Run `mix quality` before committing to ensure tests pass and coverage maintained

## Pull Request Checklist

- [ ] `mix quality` passes (format + credo + coverage ≥82%)
- [ ] Tests added/updated for new behavior
- [ ] Cassettes refreshed if prompts/tools changed
- [ ] Guides updated if public API changed
- [ ] Environment variables documented if new config added

## Context for AI Agents

When working on this codebase:

1. **Cassette changes**: If you modify prompts, instructions, or tool definitions, tests will fail until cassettes are re-recorded. This is intentional and ensures test determinism.

2. **Two-endpoint design**: Always consider whether changes affect Responses API, Chat Completions, or both. Test coverage should include both paths where applicable.

3. **Streaming is universal**: Even `Aquila.ask/2` uses streaming internally. The engine always streams; synchronous mode just buffers the result.

4. **Tool context threading**: Tools can update shared state via `{:ok, value, context_patch}` return format. Context merges forward through tool loop.

5. **Transport abstraction**: The `Transport` behavior isolates HTTP concerns. Record/Replay are transports too, enabling deterministic tests.

6. **Normalization is critical**: Body normalization in `Transport.Body` ensures cassettes remain stable despite insignificant differences (whitespace, key order, metadata).
