defmodule AquilaEngineTest do
  use ExUnit.Case, async: true

  alias Aquila.Tool

  defmodule CaptureTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(req) do
      capture(req)
      {:ok, %{}}
    end

    @impl true
    def get(req) do
      capture(req)
      {:ok, %{"ok" => true}}
    end

    @impl true
    def delete(req) do
      capture(req)
      {:ok, %{"deleted" => true}}
    end

    @impl true
    def stream(req, callback) do
      capture(req)

      callback.(%{type: :delta, content: "chunk"})
      callback.(%{type: :done, status: :completed, meta: %{usage: %{}}})

      {:ok, make_ref()}
    end

    defp capture(req) do
      if receiver = Process.get(:capture_test_pid) do
        send(receiver, {:captured, req})
      end
    end
  end

  describe "ask/2" do
    test "aggregates streamed text into a response" do
      response = Aquila.ask("Hi there", cassette: "basic")

      assert %Aquila.Response{text: "Hello world", meta: meta} = response
      assert meta[:usage]["completion_tokens"] == 2
      assert meta[:endpoint] == :responses
    end
  end

  describe "stream/2" do
    test "delivers chunks to the collector sink" do
      sink = Aquila.Sink.collector(self())

      {:ok, ref} = Aquila.stream("Stream me", sink: sink, cassette: "stream-demo")

      assert_receive {:aquila_chunk, "Partial", ^ref}
      assert_receive {:aquila_chunk, " stream", ^ref}
      assert_receive {:aquila_done, "Partial stream", meta, ^ref}
      assert meta[:tags] == ["demo"]
    end
  end

  describe "tool loop" do
    test "invokes custom tool and continues streaming" do
      tool =
        Tool.new(
          "add",
          [
            description: "Adds two numbers",
            parameters: %{
              "type" => "object",
              "properties" => %{
                "a" => %{"type" => "number"},
                "b" => %{"type" => "number"}
              },
              "required" => ["a", "b"]
            }
          ],
          fn %{"a" => a, "b" => b} -> %{sum: a + b} end
        )

      response = Aquila.ask("compute", tools: [tool], cassette: "tool-loop")

      assert response.text == "Result: 5"
      assert [%{name: "add", call_id: "call_1"}] = response.meta[:tool_calls]
    end
  end

  describe "store option" do
    setup do
      Process.put(:capture_test_pid, self())
      on_exit(fn -> Process.delete(:capture_test_pid) end)
      :ok
    end

    test "is forwarded to the Responses API" do
      Aquila.ask("Record me", store: true, transport: CaptureTransport)

      assert_receive {:captured, %{endpoint: :responses, body: body}}
      assert body[:store]
    end

    test "is omitted for Chat Completions" do
      Aquila.ask("Record me", store: true, transport: CaptureTransport, endpoint: :chat)

      assert_receive {:captured, %{endpoint: :chat, body: body}}
      refute Map.has_key?(body, :store)
    end
  end

  describe "built-in tools" do
    setup do
      Process.put(:capture_test_pid, self())
      on_exit(fn -> Process.delete(:capture_test_pid) end)
      :ok
    end

    test "accepts atom names" do
      Aquila.ask("run code", tools: [:code_interpreter], transport: CaptureTransport)

      assert_receive {:captured, %{body: body}}
      assert [tool] = fetch_tools(body)
      assert tool_type(tool) == "code_interpreter"
    end

    test "coerces maps with atom type" do
      Aquila.ask(
        "search",
        tools: [%{"type" => :file_search, "max_results" => 10}],
        transport: CaptureTransport
      )

      assert_receive {:captured, %{body: body}}
      assert [tool] = fetch_tools(body)
      assert tool_type(tool) == "file_search"
      assert tool_value(tool, "max_results") == 10
    end

    test "raises for unknown built-in names" do
      assert_raise ArgumentError, fn ->
        Aquila.ask("oops", tools: [:not_a_tool], transport: CaptureTransport)
      end
    end
  end

  defp fetch_tools(%{tools: tools}), do: tools
  defp fetch_tools(%{"tools" => tools}), do: tools

  defp tool_type(tool), do: tool_value(tool, :type)

  defp tool_value(tool, key) when is_map(tool) do
    Map.get(tool, key) || Map.get(tool, to_string(key))
  end
end
