defmodule Aquila.EngineInternalTest do
  use ExUnit.Case, async: false

  defmodule ScriptedTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req) do
      case fetch(:posts) do
        nil -> {:ok, %{"ok" => true}}
        fun when is_function(fun, 0) -> fun.()
        value -> value
      end
    end

    @impl true
    def get(_req) do
      {:ok, %{"ok" => true}}
    end

    @impl true
    def delete(_req) do
      {:ok, %{"deleted" => true}}
    end

    @impl true
    def stream(_req, callback) do
      events = fetch(:events) || []
      Enum.each(events, callback)
      {:ok, make_ref()}
    end

    def put_events(events) when is_list(events) do
      :persistent_term.put({__MODULE__, :events}, events)
    end

    def put_posts(posts) do
      :persistent_term.put({__MODULE__, :posts}, posts)
    end

    defp fetch(key) do
      term_key = {__MODULE__, key}

      case :persistent_term.get(term_key, :none) do
        :none ->
          nil

        value ->
          :persistent_term.erase(term_key)
          value
      end
    end
  end

  setup do
    Application.put_env(:aquila, :transport, ScriptedTransport)

    on_exit(fn ->
      Application.delete_env(:aquila, :transport)
      :persistent_term.erase({ScriptedTransport, :events})
      :persistent_term.erase({ScriptedTransport, :posts})
    end)

    :ok
  end

  test "stream mode delivers chunk events" do
    ScriptedTransport.put_events([
      %{type: :delta, content: "Hello"},
      %{type: :done, status: :completed, meta: %{}}
    ])

    sink = Aquila.Sink.collector(self())

    assert {:ok, ref} = Aquila.stream("hi", transport: ScriptedTransport, sink: sink)

    assert_receive {:aquila_chunk, "Hello", ^ref}
    assert_receive {:aquila_done, "Hello", %{}, ^ref}
  end

  test "fallback text is used when no chunks arrive" do
    ScriptedTransport.put_events([
      %{type: :done, status: :completed, meta: %{_fallback_text: "Fallback", id: "resp_1"}}
    ])

    response = Aquila.ask("no chunks", transport: ScriptedTransport)

    assert response.text == "Fallback"
    assert response.meta[:id] == "resp_1"
  end

  test "tool events are merged into meta" do
    tool =
      Aquila.Tool.new(
        "adder",
        [
          parameters: %{
            type: :object,
            properties: %{a: %{type: :integer}, b: %{type: :integer}}
          }
        ],
        fn _ -> %{sum: 3} end
      )

    ScriptedTransport.put_events([
      %{
        type: :tool_call,
        id: "call_1",
        call_id: "call_1",
        name: "adder",
        args_fragment: ~s({"a":1})
      },
      %{type: :tool_call_end, id: "call_1", call_id: "call_1", name: "adder", args: %{"a" => 1}},
      %{type: :done, status: :requires_action, meta: %{}},
      %{type: :delta, content: "Result: 3"},
      %{
        type: :done,
        status: :completed,
        meta: %{tool_calls: [%{id: "call_1", call_id: "call_1", name: "adder"}]}
      }
    ])

    response = Aquila.ask("compute", tools: [tool], transport: ScriptedTransport)

    assert response.text == "Result: 3"
    [%{name: "adder"} = call | _] = response.meta[:tool_calls]
    assert call[:call_id] == "call_1"
  end

  test "tool context is passed to callback" do
    parent = self()

    tool =
      Aquila.Tool.new(
        "echo",
        [
          parameters: %{
            type: :object,
            properties: %{message: %{type: :string, required: true}}
          }
        ],
        fn args, ctx ->
          send(parent, {:tool_context, ctx})
          %{echo: args["message"]}
        end
      )

    ScriptedTransport.put_events([
      %{
        type: :tool_call,
        id: "call_1",
        call_id: "call_1",
        name: "echo",
        args_fragment: ~s({"message":"hi"})
      },
      %{
        type: :tool_call_end,
        id: "call_1",
        call_id: "call_1",
        name: "echo",
        args: %{"message" => "hi"}
      },
      %{type: :done, status: :requires_action, meta: %{}},
      %{type: :delta, content: "Echo"},
      %{type: :done, status: :completed, meta: %{}}
    ])

    context = %{current_user: 123}

    _response =
      Aquila.ask("echo", tools: [tool], tool_context: context, transport: ScriptedTransport)

    assert_receive {:tool_context, ^context}
  end

  test "fetch_full_response is used when streaming yields no chunks" do
    ScriptedTransport.put_events([
      %{type: :done, status: :completed, meta: %{}}
    ])

    ScriptedTransport.put_posts({
      :ok,
      %{
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Full body"}]
          }
        ],
        "usage" => %{"total_tokens" => 42}
      }
    })

    response = Aquila.ask("need full body", transport: ScriptedTransport)

    assert response.text == "Full body"
    assert response.meta[:usage]["total_tokens"] == 42
  end
end
