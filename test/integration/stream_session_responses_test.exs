defmodule Aquila.StreamSessionResponsesTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  alias Aquila.StreamSession
  alias Aquila.Transport.Cassette, as: RecorderCassette

  defmodule StubTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def get(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def delete(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def stream(_req, callback) do
      events = [
        %{type: :response_ref, id: "resp_stub"},
        %{type: :delta, content: "Hello"},
        %{type: :delta, content: " from Responses"},
        %{type: :usage, usage: %{"total_tokens" => 5}},
        %{type: :done, status: :completed, meta: %{usage: %{"total_tokens" => 5}}}
      ]

      Enum.each(events, fn event -> callback.(event) end)
      {:ok, make_ref()}
    end
  end

  setup do
    {:ok, supervisor} = Task.Supervisor.start_link()
    pubsub = start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})

    original_transport = Application.get_env(:aquila, :transport)
    original_recorder = Application.get_env(:aquila, :recorder, [])

    Application.put_env(:aquila, :transport, Aquila.Transport.Record)

    Application.put_env(
      :aquila,
      :recorder,
      Keyword.put(original_recorder, :transport, StubTransport)
    )

    on_exit(fn ->
      Application.put_env(:aquila, :transport, original_transport)
      Application.put_env(:aquila, :recorder, original_recorder)

      if Process.alive?(supervisor), do: Process.exit(supervisor, :normal)
      if Process.alive?(pubsub), do: Process.exit(pubsub, :normal)
    end)

    {:ok, supervisor: supervisor}
  end

  test "stream session hits Responses endpoint when assistant opts in", %{supervisor: supervisor} do
    aquila_cassette "stream_session/responses/assistant" do
      Phoenix.PubSub.subscribe(__MODULE__.PubSub, "aquila:session:session-responses")

      assistant =
        Aquila.Assistant.new(
          model: "gpt-4o-mini",
          instructions: "Respond enthusiastically."
        )
        |> Aquila.Assistant.with_endpoint(:responses)

      {:ok, pid} =
        StreamSession.start(
          supervisor: supervisor,
          pubsub: __MODULE__.PubSub,
          session_id: "session-responses",
          assistant: assistant,
          content: "Hello from the user",
          timeout: 1_000
        )

      monitor = Process.monitor(pid)

      assert_receive {:aquila_stream_delta, "session-responses", "Hello"}, 1_000
      assert_receive {:aquila_stream_delta, "session-responses", " from Responses"}, 1_000

      assert_receive {:aquila_stream_usage, "session-responses", %{"total_tokens" => 5}}, 1_000
      assert_receive {:aquila_stream_complete, "session-responses"}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000

      assert {:ok, meta} = RecorderCassette.read_meta("stream_session/responses/assistant", 1)

      assert meta["endpoint"] == "responses"
      assert String.ends_with?(meta["url"], "/responses")

      assert get_in(meta, ["body", "input"]) == [
               %{
                 "content" => [
                   %{"text" => "Hello from the user", "type" => "input_text"}
                 ],
                 "role" => "user"
               }
             ]
    end
  end
end
