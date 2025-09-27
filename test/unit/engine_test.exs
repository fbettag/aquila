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
end
