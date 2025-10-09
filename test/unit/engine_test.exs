unless Code.ensure_loaded?(Ecto.Changeset) do
  defmodule Ecto.Changeset do
    defstruct [:errors]

    def traverse_errors(%__MODULE__{errors: errors}, mapper) do
      errors
      |> Enum.reduce(%{}, fn {field, {msg, opts}}, acc ->
        formatted = mapper.({msg, opts})
        Map.update(acc, field, [formatted], &[formatted | &1])
      end)
      |> Enum.map(fn {field, messages} -> {field, Enum.reverse(messages)} end)
    end
  end
end

defmodule Aquila.EngineTest do
  use ExUnit.Case, async: false

  alias Aquila.Engine
  alias Aquila.Tool

  defmodule RoundRobinTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def get(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def delete(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def stream(_req, callback) do
      round = Process.get(:engine_test_round, 0)
      script = script_value()

      events = Enum.at(script, round, [])

      Enum.each(events, fn
        event when is_map(event) -> callback.(event)
      end)

      Process.put(:engine_test_round, round + 1)
      {:ok, make_ref()}
    end

    defp script_value do
      case :persistent_term.get({__MODULE__, :script}, :undefined) do
        :undefined -> default_script()
        value -> value
      end
    end

    defp default_script do
      [
        [
          %{
            type: :tool_call,
            id: "adder-call",
            name: "adder",
            args_fragment: "{\"a\":1",
            call_id: "adder-call"
          },
          %{
            type: :tool_call,
            id: "adder-call",
            name: "adder",
            args_fragment: ",\"b\":2}",
            call_id: "adder-call"
          },
          %{
            type: :done,
            status: :requires_action,
            meta: %{"stage" => "tools"}
          }
        ],
        [
          %{type: :delta, content: "Result: 3"},
          %{type: :response_ref, id: "resp-123"},
          %{type: :usage, usage: %{"input_tokens" => 5, "output_tokens" => 2}},
          %{type: :done, status: :completed, meta: %{"additional" => "info"}}
        ]
      ]
    end
  end

  setup do
    on_exit(fn ->
      Process.delete(:engine_test_round)
      :persistent_term.erase({RoundRobinTransport, :script})
    end)

    :ok
  end

  defp tool_schema do
    %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "number"},
        "b" => %{"type" => "number"}
      },
      "required" => ["a", "b"]
    }
  end

  test "run processes tool calls, aggregates usage, and returns enriched metadata" do
    tool =
      Tool.new("adder", [parameters: tool_schema()], fn %{"a" => a, "b" => b} ->
        %{"sum" => a + b}
      end)

    response =
      Engine.run("compute",
        transport: RoundRobinTransport,
        tools: [tool],
        endpoint: :responses,
        base_url: "https://api.openai.com/v1/responses"
      )

    assert response.text == "Result: 3"
    assert response.meta[:status] == :completed
    assert response.meta[:endpoint] == :responses
    assert response.meta[:model] == "gpt-4o-mini"

    assert response.meta[:tool_calls] == [
             %{id: "adder-call", name: "adder", call_id: "adder-call"}
           ]

    assert response.meta[:usage] == %{"input_tokens" => 5, "output_tokens" => 2}
    assert response.meta["stage"] == "tools"
    assert response.meta["additional"] == "info"
    assert response.raw[:events] |> Enum.any?(fn event -> event.type == :tool_call end)
  end

  test "tool context accumulates patches returned from {:ok, result, context}" do
    script = [
      [
        %{
          type: :tool_call,
          id: "remember-1",
          name: "remember",
          args_fragment: "{}",
          call_id: "remember-1"
        },
        %{
          type: :tool_call,
          id: "remember-2",
          name: "remember",
          args_fragment: "{}",
          call_id: "remember-2"
        },
        %{type: :done, status: :requires_action, meta: %{}}
      ],
      [
        %{type: :delta, content: "Done!"},
        %{type: :done, status: :completed, meta: %{}}
      ]
    ]

    :persistent_term.put({RoundRobinTransport, :script}, script)
    Process.put(:engine_test_round, 0)

    parent = self()

    remember =
      Tool.new("remember", [parameters: %{"type" => "object", "properties" => %{}}], fn _args,
                                                                                        ctx ->
        context = ctx || %{events: []}
        send(parent, {:ctx_seen, context})

        history = Map.get(context, :events, [])
        marker = "call_#{length(history) + 1}"

        {:ok, "ack #{marker}", %{events: history ++ [marker]}}
      end)

    response =
      Engine.run("remember",
        transport: RoundRobinTransport,
        tools: [remember],
        endpoint: :responses,
        base_url: "https://api.openai.com/v1/responses",
        tool_context: %{events: []}
      )

    assert_receive {:ctx_seen, %{events: []}}, 200
    assert_receive {:ctx_seen, %{events: ["call_1"]}}, 200

    assert response.text == "Done!"
    assert response.meta[:status] == :completed
  end

  test "tool errors are normalised into deterministic payloads and streamed" do
    error_tool =
      Tool.new("failing", [parameters: tool_schema()], fn _args ->
        {:error, "validation failed"}
      end)

    script = [
      [
        %{
          type: :tool_call,
          id: "failing-call",
          name: "failing",
          args_fragment: "{}",
          call_id: "failing-call"
        },
        %{type: :done, status: :requires_action, meta: %{}}
      ],
      [
        %{type: :delta, content: "No content"},
        %{type: :done, status: :completed, meta: %{}}
      ]
    ]

    :persistent_term.put({RoundRobinTransport, :script}, script)
    Process.put(:engine_test_round, 0)

    sink = Aquila.Sink.collector(self())

    {:ok, ref} =
      Engine.run("compute",
        transport: RoundRobinTransport,
        tools: [error_tool],
        endpoint: :responses,
        base_url: "https://api.openai.com/v1/responses",
        stream: true,
        sink: sink
      )

    assert_receive {:aquila_tool_call, :start, %{name: "failing"}, ^ref}
    assert_receive {:aquila_tool_call, :result, %{output: output}, ^ref}
    assert output == "Operation failed\nvalidation failed"
    assert_receive {:aquila_done, "No content", meta, ^ref}
    assert meta[:status] == :completed
  end

  test "tool changeset errors are rendered with detailed messages" do
    script = [
      [
        %{
          type: :tool_call,
          id: "changeset-call",
          name: "changeset_tool",
          args_fragment: "{}",
          call_id: "changeset-call"
        },
        %{type: :done, status: :requires_action, meta: %{}}
      ],
      [
        %{type: :delta, content: "Handled"},
        %{type: :done, status: :completed, meta: %{}}
      ]
    ]

    :persistent_term.put({RoundRobinTransport, :script}, script)
    Process.put(:engine_test_round, 0)

    changeset =
      %Ecto.Changeset{
        errors: [
          name: {"can't be blank", []},
          tags: {"must be %{type}", [type: {:array, :string}]}
        ]
      }

    tool =
      Tool.new("changeset_tool", [parameters: tool_schema()], fn _args ->
        {:error, changeset}
      end)

    sink = Aquila.Sink.collector(self())

    {:ok, ref} =
      Engine.run("compute",
        transport: RoundRobinTransport,
        tools: [tool],
        endpoint: :responses,
        base_url: "https://api.openai.com/v1/responses",
        stream: true,
        sink: sink
      )

    assert_receive {:aquila_tool_call, :start, %{name: "changeset_tool"}, ^ref}
    assert_receive {:aquila_tool_call, :result, %{output: output}, ^ref}

    assert output ==
             "Operation failed\nName: can't be blank\nTags: must be array of string"

    assert_receive {:aquila_done, "Handled", meta, ^ref}
    assert meta[:status] == :completed
  end

  test "tool context patches apply when tool returns {:error, result, context}" do
    script = [
      [
        %{
          type: :tool_call,
          id: "remember-1",
          name: "remember",
          args_fragment: "{}",
          call_id: "remember-1"
        },
        %{
          type: :tool_call,
          id: "remember-2",
          name: "remember",
          args_fragment: "{}",
          call_id: "remember-2"
        },
        %{type: :done, status: :requires_action, meta: %{}}
      ],
      [
        %{type: :delta, content: "Recovered"},
        %{type: :done, status: :completed, meta: %{}}
      ]
    ]

    :persistent_term.put({RoundRobinTransport, :script}, script)
    Process.put(:engine_test_round, 0)

    parent = self()
    sink = Aquila.Sink.collector(parent)

    remember =
      Tool.new("remember", [parameters: %{"type" => "object", "properties" => %{}}], fn _args,
                                                                                        ctx ->
        context = ctx || %{events: []}
        send(parent, {:ctx_seen, context})

        history = Map.get(context, :events, [])
        marker = "call_#{length(history) + 1}"
        patch = %{events: history ++ [marker]}

        case history do
          [] -> {:error, "needs retry", patch}
          _ -> {:ok, "recovered", patch}
        end
      end)

    {:ok, ref} =
      Engine.run("remember",
        transport: RoundRobinTransport,
        tools: [remember],
        endpoint: :responses,
        base_url: "https://api.openai.com/v1/responses",
        tool_context: %{events: []},
        stream: true,
        sink: sink
      )

    assert_receive {:aquila_tool_call, :start, %{id: "remember-1"}, ^ref}, 200
    assert_receive {:ctx_seen, %{events: []}}, 200

    assert_receive {:aquila_tool_call, :result, first_event, ^ref}, 200
    assert first_event.status == :error
    assert first_event.output == "Operation failed\nneeds retry"
    assert first_event.context_patch == %{events: ["call_1"]}
    assert first_event.context == %{events: ["call_1"]}

    assert_receive {:aquila_tool_call, :start, %{id: "remember-2"}, ^ref}, 200
    assert_receive {:ctx_seen, %{events: ["call_1"]}}, 200

    assert_receive {:aquila_tool_call, :result, second_event, ^ref}, 200
    assert second_event.status == :ok
    assert second_event.output == "recovered"
    assert second_event.context_patch == %{events: ["call_1", "call_2"]}
    assert second_event.context == %{events: ["call_1", "call_2"]}

    assert_receive {:aquila_done, "Recovered", meta, ^ref}, 200
    assert meta[:status] == :completed
  end
end
