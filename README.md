# Aquila

Aquila is a batteries-included Elixir library for orchestrating OpenAI-compatible
Responses and Chat Completions APIs (including proxies that mimic them). The
name comes from the Latin word for *eagle*—a nod to the sharp perspective we
want over streaming responses and a friendly companion to Phoenix in Elixir’s
mythological lineup.

## Highlights

- **Unified orchestration** – `Aquila.ask/2` buffers a full response while
  `Aquila.stream/2` emits chunks. Chat Completions is the default; set
  `endpoint: :responses` to target the Responses API.
- **Tool calling that just works** – declare tools with `Aquila.Tool.new/3` and
  Aquila will decode arguments, execute your callback, and feed the output back
  to the model.
- **Context-aware tools** – supply `tool_context:` when calling Aquila so your
  tool callbacks receive application state alongside model arguments.
- **Streaming sinks** – pipe events into LiveView, GenServers, controllers, or custom
  callbacks with `Aquila.Sink`. Telemetry events are emitted for start, chunk,
  tool invocation, and completion.
- **Deterministic fixtures** – recorder/replay transports capture request and
  streaming payloads, canonicalise prompts, and fail loudly if recordings drift.
- **Response storage** – pass `store: true` to opt-in to OpenAI’s managed
  response storage and use `Aquila.retrieve_response/2` / `Aquila.delete_response/2`
  to manage conversations later. The flag is ignored automatically for Chat
  Completions.
- **Audio transcription** – `Aquila.transcribe_audio/2` wraps the OpenAI audio
  transcription endpoint with multipart uploads and sensible defaults.
- **Multi-provider ready** – pair Aquila with
  [LiteLLM](https://docs.litellm.ai/docs/) when you need Anthropic, Azure
  OpenAI, or other providers behind an OpenAI-compatible endpoint.

## Quick Start

Add Aquila to your dependencies from Hex (preferred) or directly from GitHub:

```elixir
def deps do
  [
    {:aquila, "~> 0.1.0"}
    # or, for bleeding edge development:
    # {:aquila, github: "fbettag/aquila"}
  ]
end
```

Configure credentials (typically in `config/runtime.exs`):

```elixir
config :aquila, :openai,
  api_key: System.fetch_env!("OPENAI_API_KEY"),
  base_url: "https://api.openai.com/v1",
  default_model: "gpt-4o-mini",
  transcription_model: "gpt-4o-mini-transcribe",
  request_timeout: 30_000

config :aquila, :recorder,
  path: "test/support/fixtures/aquila_cassettes",
  transport: Aquila.Transport.OpenAI
```

Ask a model:

```elixir
iex> Aquila.ask("Explain OTP supervision", instructions: "Keep it short.").text
"OTP supervision arranges workers into a restartable tree..."
```

Stream results:

```elixir
{:ok, ref} =
  Aquila.stream("Summarise this repo",
    instructions: "Three bullet points",
    sink: Aquila.Sink.pid(self())
  )

receive do
  {:aquila_chunk, chunk, ^ref} -> IO.write(chunk)
  {:aquila_done, _text, meta, ^ref} -> IO.inspect(meta, label: "usage")
end
```

### Transcribe Audio

Use `Aquila.transcribe_audio/2` when you need OpenAI’s speech-to-text API.
The helper reads the file, attaches metadata, and honours the configured
credentials.

```elixir
{:ok, transcript} =
  Aquila.transcribe_audio("/tmp/recording.webm",
    form_fields: [temperature: 0],
    response_format: "text"
  )

IO.puts(transcript)
```

Pass `raw: true` to receive the provider response without post-processing when
requesting formats like `json` or `verbose_json`.

### Persist Responses

The Responses API can store generated content for later retrieval. When you
want OpenAI to persist the output, call `Aquila.ask/2` or `Aquila.stream/2`
with `endpoint: :responses` and `store: true`. Aquila ignores `store` when
talking to Chat Completions, keeping existing flows compatible.

Stored conversations expose their `response_id` inside `response.meta`. Use the
new helpers to round-trip that identifier:

```elixir
response = Aquila.ask("Store this", store: true, endpoint: :responses)
{:ok, stored} = Aquila.retrieve_response(response.meta[:response_id])
{:ok, %{"deleted" => true}} = Aquila.delete_response(response.meta[:response_id])
```

Recorder cassettes capture the GET and DELETE traffic as well, so your tests
stay deterministic even while exercising retrieval workflows.

## Tool Calling

```elixir
summarise =
  Aquila.Tool.new("summarise",
    parameters: %{
      type: :object,
      properties: %{
        text: %{type: :string, required: true, description: "Text to summarise"},
        max_sentences: %{type: :integer}
      }
    },
    fn %{"text" => text, "max_sentences" => limit}, _ctx ->
      %{summary: Text.summary(text, sentences: limit || 3)}
    end
  )

Aquila.ask("Summarise the attached text", tools: [summarise])
```

When you opt into the Responses API (`endpoint: :responses`), Aquila streams
tool-call fragments, executes the callback, and continues the conversation using the returned
`response_id`, letting you swap instructions mid-thread.

Pass `tool_context:` when calling `Aquila.ask/2` or `Aquila.stream/2` to supply
application state (current user, DB repos, etc.) that will be injected as the
second argument to each tool callback. Leave the option unset and existing
arity-1 tools keep working unchanged.

Callbacks can return strings or maps as before, but they may also use tuples to
signal success, failure, and context updates:

- `{:ok, value}` behaves the same as returning `value`.
- `{:error, reason}` is normalised into a deterministic string payload.
- `{:ok | :error, value, context_patch}` merges `context_patch` (a map or keyword
  list) into the running `tool_context`, and the patch is echoed on the
  `:tool_call_result` event so callers can persist the update.
- `{:error, changeset}` formats Ecto changeset errors into readable sentences,
  handy when surfacing validation feedback to the model.

## Streaming Sinks & Telemetry

- `Aquila.Sink.pid/2` – sends tuples such as `{:aquila_chunk, chunk, ref}` to a
  process so you can react inside supervisors, GenServers, or UI code.
- `Aquila.Sink.fun/1` – wraps a two-arity callback.
- `Aquila.Sink.collector/1` – mirrors events back to the caller for assertions.

Telemetry events fire on `[:aquila, :stream, :start | :chunk | :stop]` and
`[:aquila, :tool, :invoke]` so you can attach metrics or trace instrumentation.

## Cassette Recording & Replay

The recorder transport automatically captures:

- Streaming events (`<name>.sse.jsonl`)
- Metadata (URL, headers, normalised request body) (`<name>.meta.jsonl`)

During replay, request bodies are normalised again; mismatches raise immediately with a
list of files to delete. `Aquila.Transport.Record` powers the test suite so
missing cassettes are recorded automatically while existing fixtures replay
locally and stay verified.

To customize transports, set `config :aquila, :transport, ...` in the relevant
environment or pass `transport:` directly to `Aquila.ask/2` / `Aquila.stream/2`.
By default Aquila uses `Aquila.Transport.OpenAI`, so many apps need no
configuration at all.

## Multi-Provider Routing via LiteLLM

Run LiteLLM as a sidecar and point `config :aquila, :openai, base_url:` at the
proxy (or pass `base_url:`/`transport:` options at runtime). LiteLLM keeps the
OpenAI wire format intact, so Aquila’s streaming sinks, tool loop, and cassette
recorder continue to work with Anthropic, Claude, Azure OpenAI, or any other
provider it supports.

## Project Layout

- `lib/aquila.ex` – public API (`ask/2`, `stream/2`, `retrieve_response/2`,
  `delete_response/2`).
- `lib/aquila/engine.ex` – orchestration, streaming loop, tool integration.
- `lib/aquila/transport/` – HTTP adapter, recorder, replay utilities.
- `lib/aquila/sink.ex` – sink helpers for delivering streaming events.
- `guides/` – HexDocs extras covering setup, streaming, cassette usage,
  LiveView, Oban, LiteLLM, and code quality.
- `test/` – cassette-backed unit tests and streaming transport coverage.

## Development Workflow

```shell
mix deps.get
mix compile
mix quality   # format + credo
mix test      # requires prerecorded cassettes
mix docs      # generate HTML docs in _build/dev/lib/aquila/doc
```

### Live OpenAI Tests

The suite includes an optional integration check that hits the real OpenAI
Responses API. Set an API key and the `:live` tests will run automatically with
`mix test`:

```shell
export OPENAI_API_KEY=sk-...
export OPENAI_BASE_URL=.../v1
mix test
```

To focus solely on the live tests (or force them when the key is missing), pass
`mix test --only live`. To always skip them, use `mix test --exclude live`.

The integration sends a single prompt and asserts the library can complete a
synchronous request end-to-end. Running it consumes API quota and requires
outbound network access.

Before opening a PR:

1. Refresh cassettes when prompts, instructions, or tool definitions change.
2. Ensure `mix quality` and `mix test` pass.
3. Update guides if you introduce new configuration or workflows.

Aquila's goal is to be the reference toolkit for building Elixir and Phoenix
experiences on top of OpenAI-compatible models. Issues and contributions are
very welcome!

## License

MIT License - see [LICENSE](LICENSE) file for details.

Copyright © 2025 Franz Bettag
