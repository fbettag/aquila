# Cassette Recording & Testing

The recorder transport guarantees deterministic tests by persisting request
and streaming responses to disk. Prompt changes are detected via canonical
request hashing, forcing you to re-record when inputs drift.

## Configuration

```elixir
# config/test.exs
config :aquila, :transport, Aquila.Transport.Record
config :aquila, :recorder,
  path: "test/support/cassettes",
  transport: Aquila.Transport.OpenAI
```

- `Aquila.Transport.Record` wraps the inner transport and automatically
  records missing cassettes. Once a cassette exists it replays it locally and
  verifies the prompt hash on every run.
- Cassette files live under the configured directory with the pattern
  `<name>-<index>.(json|sse.jsonl|meta.json)`.
  Non-streaming calls now embed the HTTP method in metadata so `GET` and
  `DELETE` recordings coexist alongside the `POST` entries that power
  streaming sessions.

## Recording Behaviour

1. When a cassette is **missing**, the recorder delegates to the inner
   transport, mirrors the streaming events to your sink, and saves both the
   HTTP response and the SSE stream.
2. Metadata captures the model, URL, headers, and a canonical body hash. The
   hash is compared on subsequent runs.
3. When a cassette **exists**, the recorder verifies the hash and either
   replays the payload or raises with instructions to delete stale files.

## Writing Tests

```elixir
use Aquila.Cassette

@test "streams deterministic chunks" do
  aquila_cassette "greetings" do
    {:ok, ref} = Aquila.stream("hello")
    assert_receive {:aquila_chunk, chunk, ^ref}
    assert chunk =~ "hi"
  end
end
```

`aquila_cassette/3` stores the cassette name in the process dictionary so any
nested Aquila calls (even deep inside LiveView helpers) inherit it
automatically. Pass additional options—such as `cassette_index:`—to the macro
when you need to target a specific fixture.

If you introduce Mox-powered doubles for transports or sinks, add
`setup :verify_on_exit!` / `setup :set_mox_global` inside that specific test
module. Plain cassette-backed tests do not need them.

Recording should happen inside the test environment so your dev runtime remains
live-call free. For most suites the `config/test.exs` snippet above is enough—no
additional `Application.put_env/3` calls or Mox boilerplate are required unless
you override transports within an individual test.

When you need to refresh fixtures, run the affected tests with a
real `OPENAI_API_KEY` available. `Record` will detect missing or stale
cassettes, proxy the request to the configured OpenAI transport (redacting
Authorization headers automatically), store the new fixtures, and replay them
on subsequent runs.

## Troubleshooting

- **Prompt mismatch raised** – the error message lists the cassette files to
  delete (meta, SSE JSONL, and buffered JSON). Remove them and rerun the test
  to capture a fresh recording. This happens whenever you tweak prompts,
  tools, or instructions, which is exactly when you want a new cassette.
- **Missing cassette in CI** – ensure `config/test.exs` keeps
  `Aquila.Transport.Record` configured. The recorder replays locally when the
  cassette is present and fails loudly when it is not, which keeps CI hermetic.
