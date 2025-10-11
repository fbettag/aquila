defmodule Aquila.StreamSessionTest do
  use ExUnit.Case

  alias Aquila.StreamSession
  import ExUnit.CaptureLog
  require Logger

  defmodule Transport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{"ok" => true}}
    @impl true
    def get(_req), do: {:ok, %{"ok" => true}}
    @impl true
    def delete(_req), do: {:ok, %{"ok" => true}}

    def configure(config, opts \\ []) do
      :persistent_term.put({__MODULE__, :script}, config)

      if receiver = Keyword.get(opts, :receiver) do
        :persistent_term.put({__MODULE__, :receiver}, receiver)
      end
    end

    def reset do
      :persistent_term.erase({__MODULE__, :script})
      :persistent_term.erase({__MODULE__, :receiver})
    end

    @impl true
    def stream(_req, callback) do
      round = Process.get(:stream_session_round, 0)
      config = :persistent_term.get({__MODULE__, :script}, default_config())

      case config do
        {:events, rounds} ->
          events = Enum.at(rounds, round, [])
          Enum.each(events, &callback.(&1))
          Process.put(:stream_session_round, round + 1)
          ref = make_ref()

          if receiver = :persistent_term.get({__MODULE__, :receiver}, nil) do
            send(receiver, {:transport_ref, ref})
          end

          {:ok, ref}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp default_config do
      {:events,
       [
         [
           %{type: :delta, content: "Hello"},
           %{type: :usage, usage: %{"total_tokens" => 1}},
           %{type: :done, status: :completed, meta: %{"stage" => "done"}}
         ]
       ]}
    end
  end

  defmodule Persistence do
    def configure(pid, opts \\ []) do
      :persistent_term.put({__MODULE__, :receiver}, pid)
      :persistent_term.put({__MODULE__, :config}, opts)
      :persistent_term.put({__MODULE__, :last_tool_call}, nil)
    end

    def reset do
      :persistent_term.erase({__MODULE__, :receiver})
      :persistent_term.erase({__MODULE__, :config})
      :persistent_term.erase({__MODULE__, :last_tool_call})
    end

    def on_start(session_id, content, _opts) do
      notify({:persist_start, session_id, content})

      case Keyword.get(config(), :on_start) do
        {:error, reason} -> {:error, reason}
        {:ok, state} -> {:ok, state}
        _ -> {:ok, %{chunks: []}}
      end
    end

    def on_chunk(session_id, chunk, %{chunks: chunks} = state, _opts) do
      notify({:persist_chunk, session_id, chunk})

      case Keyword.get(config(), :on_chunk) do
        {:error, reason} -> {:error, reason}
        _ -> {:ok, %{state | chunks: chunks ++ [chunk]}}
      end
    end

    def on_complete(session_id, text, state, _opts) do
      notify({:persist_complete, session_id, text, state})

      case Keyword.get(config(), :on_complete) do
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    end

    def on_error(session_id, reason, state, _opts) do
      notify({:persist_error, session_id, reason, state})
      :ok
    end

    def on_tool_call(session_id, name, result, state, _opts) do
      :persistent_term.put({__MODULE__, :last_tool_call}, {session_id, name, result})
      notify({:persist_tool_call, session_id, name, result})

      case Keyword.get(config(), :on_tool_call) do
        {:error, reason} -> {:error, reason}
        _ -> {:ok, state}
      end
    end

    def on_event(session_id, category, event, state, _opts) do
      notify({:persist_research_event, session_id, category, event})
      {:ok, state}
    end

    defp notify(message) do
      if receiver = :persistent_term.get({__MODULE__, :receiver}, nil) do
        send(receiver, message)
      end
    end

    defp config do
      :persistent_term.get({__MODULE__, :config}, [])
    end

    def last_tool_call do
      :persistent_term.get({__MODULE__, :last_tool_call}, nil)
    end
  end

  setup do
    {:ok, supervisor} = Task.Supervisor.start_link()
    pubsub = start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    original = Application.get_env(:aquila, :transport)

    Application.put_env(:aquila, :transport, Transport)
    Persistence.configure(self())

    on_exit(fn ->
      Application.put_env(:aquila, :transport, original)
      Transport.reset()
      Persistence.reset()
      Process.delete(:stream_session_round)
      Process.exit(supervisor, :normal)
      Process.exit(pubsub, :normal)
    end)

    {:ok, supervisor: supervisor}
  end

  test "broadcasts streamed events and persists session data", %{supervisor: supervisor} do
    Transport.configure(
      {:events,
       [
         [
           %{type: :delta, content: "Hello"},
           %{type: :usage, usage: %{"total_tokens" => 3}},
           %{type: :done, status: :completed, meta: %{"stage" => "finished"}}
         ]
       ]}
    )

    assistant = Aquila.Assistant.new(model: "gpt-4o-mini", instructions: "Test")

    Phoenix.PubSub.subscribe(__MODULE__.PubSub, "aquila:session:session-1")

    {:ok, _pid} =
      StreamSession.start(
        supervisor: supervisor,
        pubsub: __MODULE__.PubSub,
        session_id: "session-1",
        assistant: assistant,
        content: "Hello",
        persistence: Persistence,
        persistence_opts: [user_id: 42],
        timeout: 2_000
      )

    assert_receive {:persist_start, "session-1", "Hello"}
    assert_receive {:aquila_stream_delta, "session-1", "Hello"}
    assert_receive {:persist_chunk, "session-1", "Hello"}
    assert_receive {:aquila_stream_usage, "session-1", %{"total_tokens" => 3}}
    assert_receive {:persist_complete, "session-1", "Hello", %{chunks: ["Hello"]}}
    assert_receive {:aquila_stream_complete, "session-1"}
  end

  test "broadcasts deep research events", %{supervisor: supervisor} do
    Transport.configure(
      {:events,
       [
         [
           %{type: :event, payload: %{source: :deep_research, event: :output_item_added}},
           %{type: :done, status: :completed, meta: %{}}
         ]
       ]},
      receiver: self()
    )

    assistant = Aquila.Assistant.new(model: "openai/o3-deep-research-2025-06-26")

    Phoenix.PubSub.subscribe(__MODULE__.PubSub, "aquila:session:session-dr")

    {:ok, _pid} =
      StreamSession.start(
        supervisor: supervisor,
        pubsub: __MODULE__.PubSub,
        session_id: "session-dr",
        assistant: assistant,
        content: "Run deep research",
        persistence: Persistence,
        timeout: 2_000
      )

    assert_receive {:aquila_stream_research_event, "session-dr",
                    %{source: :deep_research, event: :output_item_added}}

    assert_receive {:persist_research_event, "session-dr", :deep_research,
                    %{source: :deep_research, event: :output_item_added}}
  end

  test "propagates transport errors to pubsub and persistence", %{supervisor: supervisor} do
    original_console = Application.get_env(:logger, :console, [])
    original_otp = Keyword.get(original_console, :handle_otp_reports, true)

    capture_log(fn ->
      Logger.configure_backend(:console, handle_otp_reports: false)

      try do
        Transport.configure({:events, [[%{type: :error, error: %{message: "boom"}}]]})

        assistant = Aquila.Assistant.new(model: "gpt-4o-mini")

        Phoenix.PubSub.subscribe(__MODULE__.PubSub, "aquila:session:session-err")

        {:ok, pid} =
          StreamSession.start(
            supervisor: supervisor,
            pubsub: __MODULE__.PubSub,
            session_id: "session-err",
            assistant: assistant,
            content: "Oops",
            persistence: Persistence,
            timeout: 2_000
          )

        monitor = Process.monitor(pid)

        assert_receive {:persist_start, "session-err", "Oops"}
        assert_receive {:persist_error, "session-err", %{message: "boom"}, %{chunks: []}}
        assert_receive {:aquila_stream_error, "session-err", %{message: "boom"}}
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
      after
        Logger.configure_backend(:console, handle_otp_reports: original_otp)
      end
    end)
  end

  test "persistence callback errors do not crash streaming", %{supervisor: supervisor} do
    capture_log(fn ->
      Transport.configure(
        {
          :events,
          [
            [
              %{
                type: :tool_call,
                id: "call-1",
                name: "noop",
                args_fragment: ~s({"ok":true}),
                call_id: "call-1"
              },
              %{
                type: :tool_call_end,
                id: "call-1",
                name: "noop",
                args: %{ok: true},
                call_id: "call-1"
              },
              %{type: :done, status: :requires_action, meta: %{}}
            ],
            [
              %{type: :delta, content: "Chunk"},
              %{type: :done, status: :completed, meta: %{usage: %{total_tokens: 1}}}
            ]
          ]
        },
        receiver: self()
      )

      Persistence.configure(self(),
        on_chunk: {:error, :chunk_failed},
        on_tool_call: {:error, :tool_failed},
        on_complete: {:error, :complete_failed}
      )

      tool =
        Aquila.Tool.new(
          "noop",
          [description: "no-op", parameters: %{"type" => "object", "properties" => %{}}],
          fn _, _ -> %{ok: true} end
        )

      assistant = Aquila.Assistant.new(model: "gpt-4o-mini", tools: [tool])

      Phoenix.PubSub.subscribe(__MODULE__.PubSub, "aquila:session:session-persist")

      {:ok, pid} =
        StreamSession.start(
          supervisor: supervisor,
          pubsub: __MODULE__.PubSub,
          session_id: "session-persist",
          assistant: assistant,
          content: "Payload",
          persistence: Persistence,
          timeout: 2_000
        )

      monitor = Process.monitor(pid)

      assert_receive {:transport_ref, _ref}

      assert_receive {:persist_start, "session-persist", "Payload"}
      assert_receive {:persist_tool_call, "session-persist", "noop", "{\"ok\":true}"}
      assert Persistence.last_tool_call() == {"session-persist", "noop", "{\"ok\":true}"}

      assert_receive {:aquila_stream_tool_call, "session-persist", :end,
                      %{name: "noop", output: "{\"ok\":true}"}}

      assert_receive {:transport_ref, _ref2}
      assert_receive {:aquila_stream_delta, "session-persist", "Chunk"}
      assert_receive {:persist_chunk, "session-persist", "Chunk"}
      assert_receive {:aquila_stream_usage, "session-persist", %{total_tokens: 1}}
      assert_receive {:aquila_stream_complete, "session-persist"}
      assert_receive {:persist_complete, "session-persist", "Chunk", %{chunks: []}}
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    end)
  end
end
