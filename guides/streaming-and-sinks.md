# Streaming and Sinks

Streaming is the default execution mode when you call `Aquila.stream/2`. The
engine normalises both Responses and Chat Completions events into a compact
set of tuples delivered to your sink.

## Sink Options

`Aquila.Sink` exposes three helpers:

- `Aquila.Sink.pid/2` – sends tuples to a process (`{:aquila_chunk, chunk, ref}`),
  optionally omitting the reference via `with_ref: false`.
- `Aquila.Sink.fun/1` – passes each event to a two-arity function.
- `Aquila.Sink.collector/2` – replays events to a supervising process with an
  internal reference, great for assertions during tests.

All sinks receive the following events:

| Event | Payload |
| --- | --- |
| `{:aquila_chunk, binary, ref}` | Incremental content chunk |
| `{:aquila_event, map, ref}` | Metadata or tool-call fragments |
| `{:aquila_done, text, meta, ref}` | Completion text and aggregated metadata |
| `{:aquila_error, reason, ref}` | Transport or orchestration error |

## Process Example

You can drive streams from any OTP process. The `GenServer` below buffers
chunks in state and logs metadata when the stream completes:

```elixir
defmodule Aquila.ChatSession do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, opts)
  end

  def init(_) do
    {:ok, %{ref: nil, buffer: ""}}
  end

  def handle_cast({:stream, prompt, opts}, state) do
    {:ok, ref} = Aquila.stream(prompt, Keyword.put(opts, :sink, Aquila.Sink.pid(self())))
    {:noreply, %{state | ref: ref, buffer: ""}}
  end

  def handle_info({:aquila_chunk, chunk, ref}, %{ref: ref} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({:aquila_done, _text, meta, ref}, %{ref: ref} = state) do
    Logger.info("stream finished", meta: meta)
    {:noreply, %{state | ref: nil}}
  end

  def handle_info({:aquila_error, reason, ref}, %{ref: ref} = state) do
    Logger.error("stream failed", reason: inspect(reason))
    {:noreply, %{state | ref: nil}}
  end
end
```

Kick off work with `GenServer.cast(session, {:stream, prompt, []})`. UI layers,
command line interfaces, and background jobs all follow the same pattern—store
the reference returned by `Aquila.stream/2` and react to the tuples emitted by
your chosen sink helper.

## Telemetry Hooks

`Aquila.Engine` emits telemetry events as chunks flow through the system. Attach
handlers to `[:aquila, :stream, :chunk]` and friends to gather buffering or
latency metrics alongside your sink-driven UI updates.

## Tips

- Combine `Aquila.Sink.collector/1` with the recorder transport to assert exact
  chunk ordering in tests.
- Use the `metadata` option when calling `Aquila.stream/2` to tag streams with
  session IDs; the recorder persists these values so you can audit playback
  later.
- When continuing a conversation, pass `previous_response_id` and updated
  instructions to pivot the assistant tone without losing context.
- Routing through LiteLLM is safe for streaming; the proxy maintains the
  event stream shape expected by the sink helpers, so you can fan out to
  multiple providers without changing UI code.

## Tool Calls During Streaming

Tool invocations surface as `{:aquila_event, %{type: :tool_call, ...}, ref}`
followed by `:tool_call_end` events. This makes it straightforward to render
“assistant is thinking” indicators or log tool payloads for debugging.

Define tools with atom-keyed schemas and an optional context argument to keep
callbacks ergonomic:

```elixir
logger =
  Aquila.Tool.new(
    "log",
    parameters: %{
      type: :object,
      properties: %{
        level: %{type: :string, required: true},
        message: %{type: :string, required: true}
      }
    },
    fn %{"level" => level, "message" => message}, ctx ->
      ctx.logger.log(level, message)
      %{status: "ok"}
    end
  )

{:ok, ref} =
  Aquila.stream(messages,
    tools: [logger],
    tool_context: %{logger: MyApp.Logger}
  )
```

Single-arity callbacks continue to work; only supply `tool_context:` when you
need to inject application state or dependencies into the tool execution.

Tool callbacks may return binaries or maps, or tuples that include a context
patch:

- `{:ok, value}` behaves like returning `value`.
- `{:error, reason}` is normalised into a deterministic error string.
- `{:ok | :error, value, context_patch}` merges `context_patch` into the active
  `tool_context` and includes both the patch and merged context on the emitted
  `:tool_call_result` event.
- `{:error, changeset}` turns Ecto validation errors into readable text without
  extra plumbing.
