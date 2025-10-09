# Deep Research Integration

Deep Research models (e.g. `openai/o3-deep-research-2025-06-26`) expose a
long-running reasoning workflow that issues web searches, evaluates sources, and
returns a structured report. Aquila ships first-class helpers for orchestrating
that experience while keeping streaming, recorder cassettes, and LiveView
integration consistent with the rest of the library.

## Prerequisites

1. Configure your OpenAI-compatible endpoint and API key in `config/runtime.exs`.
2. Record cassette fixtures with the recorder transport. Recorded metadata
   automatically masks the `Authorization` header so your API key never lands on
   disk.
3. Deep Research requires the `web_search_preview` tool. Aquila injects it by
   default; you can layer additional builtin or function tools on top.

## Synchronous API Helpers

`Aquila.deep_research_create/2` issues a background run via the Responses API
(`background: true`) and returns the provider payload:

```elixir
{:ok, run} =
  Aquila.deep_research_create(
    [%{role: :user, content: "Outline opportunities in the European battery market."}],
    reasoning: %{effort: "low"}
  )

run_id = run["id"]
```

Poll the run (for background dashboards or job processors) with
`Aquila.deep_research_fetch/2` and cancel it with `Aquila.deep_research_cancel/2`:

```elixir
{:ok, response} = Aquila.deep_research_fetch(run_id)

case response.meta[:status] do
  "completed" ->
    IO.puts("Final report:\n\n" <> response.text)

  "in_progress" ->
    :timer.sleep(5_000)
    retry()
end
```

## Streaming

Use `Aquila.deep_research_stream/2` to watch progress live. The helper simply
delegates to `Aquila.stream/2` with the required options pre-populated, so you
get chunk events, tool-call notifications, and a final `%Aquila.Response{}`:

```elixir
sink = Aquila.Sink.pid(self())
{:ok, ref} =
  Aquila.deep_research_stream(
    [
      %{role: :user,
        content: "Provide three bullet points on the impact of small modular reactors in Europe."}
    ],
    sink: sink,
    reasoning: %{effort: "medium"}
  )

receive do
  {:aquila_chunk, chunk, ^ref} ->
    IO.puts(chunk)

  {:aquila_done, _text, meta, ^ref} ->
    IO.inspect(meta, label: "usage")
end
```

### Recorder & Cassettes

Run the streaming helper inside `aquila_cassette/3` while the recorder transport
is active to capture both the JSON request/response metadata and the SSE event
timeline. Authorization headers are redacted, and Aquila fails the test if you
change the prompt without re-recording the cassette, keeping fixtures honest.

```elixir
use Aquila.Cassette

test "deep research run is deterministic" do
  aquila_cassette "deep_research/stream-basic" do
    {:ok, ref} =
      Aquila.deep_research_stream([%{role: :user, content: "Summarise the latest Mars milestone."}])

    {:ok, response} = Aquila.await_stream(ref)
    assert response.text != ""
  end
end
```

## Testing

1. Export `OPENAI_API_KEY` and `OPENAI_BASE_URL` so Aquila targets the correct
   endpoint while recording.
2. Wrap the Deep Research call with `aquila_cassette/3` (as in the example
   above) to capture both the JSON metadata and SSE timeline.
3. Record fixtures with:

   ```bash
   OPENAI_API_KEY=... OPENAI_BASE_URL=... mix test test/integration/deep_research_live_test.exs
   ```

4. Subsequent `mix test` runs replay the cassette. If you tweak prompts or
   options, delete the cassette files under
   `test/support/fixtures/aquila_cassettes/deep_research/` and re-run the command
   to refresh them. Aquila will raise a diff if recordings fall out of sync.

## LiveView Integration

`Aquila.StreamSession` broadcasts a new PubSub message when Deep Research emits
structured progress events:

```elixir
{:aquila_stream_research_event, session_id, event}
```

`Aquila.LiveView` forwards those events to the configured LiveComponent under
the `:streaming_research_event` assign key. The forwarded payload contains the
raw Deep Research event so you can render search steps, citations, or status
chips alongside the main report.

Ensure your LiveView sets `forward_to_component: {MyComponent, :component_id}`
and assigns the matching ID before starting the stream; otherwise Aquila raises
an explicit error to avoid silently dropping updates.

## Background Processing

Combine `Aquila.deep_research_create/2` with Oban or another job runner when you
want a fully asynchronous workflow:

1. Queue a job that calls `deep_research_create/2` and stores the returned
   response ID.
2. Schedule follow-up jobs that poll `deep_research_fetch/2` until the run is
   complete.
3. Deliver the final `%Aquila.Response{}` to end users through email, push
   notifications, or your LiveView UI.

Because the helpers share the normal transport stack, cassette fixtures and
retry logic behave the same as in other Aquila entry points.
