# Getting Started

This guide walks through configuring the library, issuing your first
requests, and enabling streaming output.

## Prerequisites

- Elixir 1.15+ with Mix available.
- An OpenAI-compatible API key exposed as `OPENAI_API_KEY` (or configure the
  `:api_key` option differently).
- Optional: enable [Credo](code-quality.md) to lint your project while you
  work through the guide.

## Install and Configure

1. Add the dependency and fetch packages (Hex preferred):

    ```elixir
    {:aquila, "~> 0.1.0"}
    # or, for edge builds:
    # {:aquila, github: "fbettag/aquila"}
    ```

2. Configure credentials (usually in `config/runtime.exs`):

    ```elixir
    config :aquila, :openai,
      api_key: System.fetch_env!("OPENAI_API_KEY"),
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4.1-mini",
      transcription_model: "gpt-4o-mini-transcribe"
    ```

3. Configure cassette recording for tests:

   ```elixir
   # config/test.exs
   config :aquila, :transport, Aquila.Transport.Record
   config :aquila, :recorder,
    path: "test/support/fixtures/aquila_cassettes",
     transport: Aquila.Transport.OpenAI
   ```

   Aquila already defaults to `Aquila.Transport.OpenAI`, so no runtime
   configuration is required. `Record` replays existing cassettes locally and
   captures fresh ones on demand when the normalised body diverges.

## Synchronous Requests

Use `Aquila.ask/2` for buffered responses. The function returns `%Aquila.Response{}`
with textual output, usage metadata, and the raw payload.

```elixir
response =
  Aquila.ask("Explain OTP supervision trees",
    instruction: "You are a senior Elixir tutor.",
    model: "gpt-4.1-mini"
  )

IO.puts(response.text)
```

## Streaming Requests

`Aquila.stream/2` defaults to pushing events to the calling process. Handle the
messages to update UI state incrementally or log telemetry.

```elixir
{:ok, ref} =
  Aquila.stream("Give me three talking points about BEAM performance",
    instruction: "Be concise.",
    tools: [],
    sink: Aquila.Sink.pid(self())
  )

receive do
  {:aquila_chunk, chunk, ^ref} -> IO.write(chunk)
  {:aquila_done, _text, meta, ^ref} -> IO.inspect(meta, label: "usage")
end
```

Use `Aquila.Sink.fun/1` for a callback-based sink or
`Aquila.Sink.collector/1` for deterministic test flows.

If you need to update instructions without losing context, capture the
`response_id` or `previous_response_id` from the `:done` metadata and supply
it on the next call.

### Persist Responses

The Responses API can store generated content on OpenAI for later retrieval.
Pass `endpoint: :responses` together with `store: true` while calling
`Aquila.ask/2` or `Aquila.stream/2` to enable this behaviour. The option is
ignored when the request uses the Chat Completions API.

When storage is enabled `Aquila` surfaces the resulting `response_id` inside
`response.meta`. Use `Aquila.retrieve_response/2` to fetch the persisted
conversation at a later time, and `Aquila.delete_response/2` to purge it once it
is no longer needed:

```elixir
response = Aquila.ask("Store this", store: true, endpoint: :responses)

{:ok, stored} = Aquila.retrieve_response(response.meta[:response_id])
{:ok, %{"deleted" => true}} = Aquila.delete_response(response.meta[:response_id])
```

Recorded cassettes fully capture the GET/DELETE traffic, so tests can replay
the lifecycle without making additional API calls.

## Audio Transcription

When you need speech-to-text, call `Aquila.transcribe_audio/2`. The helper uses
the configured OpenAI credentials, sends multipart uploads, and returns cleaned
text (or the raw payload when `raw: true`).

```elixir
{:ok, transcript} =
  Aquila.transcribe_audio("/tmp/meeting.webm",
    form_fields: [temperature: 0],
    response_format: "text"
  )

IO.puts(transcript)
```

Override the filename or MIME type with `:filename`/`:content_type` when your
storage backend strips extensions, and pass `:form_fields` to forward optional
parameters such as `language`.

## Tool Support

Attach custom tools via `Aquila.Tool.new/3`. The engine will call your function
when the model returns a tool invocation and stream any follow-up responses.

```elixir
sum =
  Aquila.Tool.new(
    "sum",
    parameters: %{
      type: :object,
      properties: %{
        a: %{type: :number, required: true},
        b: %{type: :number, required: true}
      }
    },
    fn %{"a" => a, "b" => b}, _ctx ->
      %{result: a + b}
    end
  )

Aquila.ask("Add 2 and 3", tools: [sum])
```

Need access to application state inside a tool? Pass `tool_context:` when
calling `Aquila.ask/2` or `Aquila.stream/2` and define your callbacks with two
arguments (`fn args, ctx -> ... end`). The context value is forwarded as the
second argument while existing single-arity callbacks keep working.

Callbacks can now return richer tuples as well as plain binaries or maps:

- `{:ok, value}` is treated the same as returning `value`.
- `{:error, reason}` yields a normalised error string.
- `{:ok | :error, value, context_patch}` merges `context_patch` (map or keyword
  list) into the running `tool_context`. The merged context is also included in
  the emitted `:tool_call_result` event so you can persist new state.
- `{:error, changeset}` renders Ecto changeset errors into readable sentences.

Schemas can stay idiomatic Elixir even when they include arrays or nested
objects—just use atom keys and optional `:required` booleans:

```elixir
chat_history =
  Aquila.Tool.new(
    "chat_history",
    parameters: %{
      type: :object,
      properties: %{
        messages: %{
          type: :array,
          required: true,
          items: %{
            type: :object,
            properties: %{
              role: %{type: :string, required: true},
              content: %{type: :string, required: true}
            }
          }
        }
      }
    },
    fn %{"messages" => messages}, _ctx -> persist(messages) end
  )
```

## Using LiteLLM for Other Providers

If you need to reach non-OpenAI providers, deploy
[LiteLLM](https://docs.litellm.ai/docs/) as an intermediary. Configure LiteLLM
to expose both the `/responses` and `/chat/completions` routes; then point this
library’s `:base_url` at the LiteLLM server. Because LiteLLM mirrors the
OpenAI wire format, `Aquila.Engine` keeps streaming, tool calls, and cassette
recording working across providers.

Continue to [Streaming and Sinks](streaming-and-sinks.md) once you are ready
to drive interactive interfaces.
