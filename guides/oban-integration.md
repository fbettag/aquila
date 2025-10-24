# Oban Integration

Oban provides durable background processing for Elixir applications. Aquila’s
API is synchronous-friendly, so you can enqueue jobs that call `Aquila.ask/2`
or `Aquila.stream/2` without any special plumbing. This guide outlines a
typical setup.

## Prerequisites

- Oban 2.17 or newer in your application’s dependencies.
- A configured Aquila transport; cassette recording is recommended for tests.
- Database migrations applied for Oban queues.

Add Oban in your own project if it is not already in place:

```elixir
{:oban, "~> 2.17"}
```

Configure queues and plugins in `config/runtime.exs` or environment-specific
files:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [llm: 10],
  plugins: [Oban.Plugins.Pruner]
```

## A Streaming Job

Use streaming when you want incremental updates or tool chaining. Capture
chunks inside the job process or forward them to another consumer.

```elixir
defmodule MyApp.Workers.StreamPrompt do
  use Oban.Worker, queue: :llm
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"prompt" => prompt}}) do
    sink = Aquila.Sink.collector(self())

    {:ok, ref} =
      Aquila.stream(prompt,
        cassette: "jobs/stream_prompt",
        sink: sink,
        metadata: %{job_id: Ecto.UUID.generate()}
      )

    collect(ref, [])
  end

  defp collect(ref, acc) do
    receive do
      {:aquila_chunk, chunk, ^ref} -> collect(ref, [chunk | acc])
      {:aquila_done, text, meta, ^ref} ->
        Logger.info("stream complete", meta: meta)
        store_output(Enum.reverse([text | acc]))
        :ok
      {:aquila_error, reason, ^ref} ->
        Logger.error("stream failed", reason: inspect(reason))
        {:error, reason}
    after
      30_000 -> {:error, :timeout}
    end
  end

  defp store_output(chunks) do
    # Persist to the database or emit events for downstream consumers.
    :ok = MyApp.ChatLogs.persist(chunks)
  end
end
```

Enqueue the worker with `MyApp.Workers.StreamPrompt.new(%{"prompt" => prompt}) |> Oban.insert()`.

## Buffered Jobs

For simpler use cases you can rely on `Aquila.ask/2` and persist the resulting
`%Aquila.Response{}` in one go:

```elixir
defmodule MyApp.Workers.GenerateSummary do
  use Oban.Worker, queue: :llm

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"text" => text}}) do
    response =
      Aquila.ask("Summarise the following", cassette: "jobs/generate_summary", tools: [],
        metadata: %{id: text[:id]},
        instructions: "Write a concise executive summary."
      )

    MyApp.Summaries.store(text[:id], response.text, response.raw)
    :ok
  end
end
```

## Testing Jobs

Pair Oban’s testing helpers with cassette replay to keep jobs deterministic.

```elixir
defmodule MyApp.Workers.GenerateSummaryTest do
  use MyApp.DataCase, async: true

  test "stores summaries" do
    job = MyApp.Workers.GenerateSummary.new(%{"text" => %{id: 123, body: "Hello"}})

    assert :ok = perform_job(job)
    assert MyApp.Summaries.fetch!(123).body =~ "Hello"
  end
end
```

If you need to record fresh cassettes, temporarily swap the configured
transport to `Aquila.Transport.OpenAI` and provide a real API key.

## Tips

- Use Oban’s [job telemetry](https://hexdocs.pm/oban/telemetry.html) to merge
  Aquila chunk metadata with queue metrics.
- Avoid long-lived jobs when streaming large outputs; break them into smaller
  prompts or attach progress checkpoints with `metadata`.
- When combining LiveView and Oban, broadcast job progress over PubSub and let
  the LiveView subscribe to updates emitted by your workers.
