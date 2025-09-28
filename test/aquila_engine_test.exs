defmodule AquilaEngineTest do
  use ExUnit.Case, async: true
  use Aquila.Cassette

  alias Aquila.Tool

  defmodule CaptureTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(req) do
      capture(req)

      posts = Process.get(:capture_posts)

      case posts do
        [next | rest] ->
          Process.put(:capture_posts, rest)
          maybe_apply(next)

        nil ->
          {:ok, %{}}

        other ->
          maybe_apply(other)
      end
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
      events = next_stream()
      Enum.each(events, callback)
      {:ok, make_ref()}
    end

    defp capture(req) do
      if receiver = Process.get(:capture_test_pid) do
        send(receiver, {:captured, req})
      end
    end

    defp next_stream do
      case Process.get(:capture_streams) do
        [next | rest] ->
          if rest == [] do
            Process.delete(:capture_streams)
          else
            Process.put(:capture_streams, rest)
          end

          next

        nil ->
          [
            %{type: :delta, content: "chunk"},
            %{type: :done, status: :completed, meta: %{usage: %{}}}
          ]
      end
    end

    defp maybe_apply(fun) when is_function(fun, 0), do: fun.()
    defp maybe_apply(value), do: value
  end

  describe "ask/2" do
    test "aggregates streamed text into a response" do
      response =
        aquila_cassette "basic" do
          Aquila.ask("Hi there")
        end

      assert response.text =~ "Hello"
      assert response.meta[:usage]["output_tokens"] >= 5
      assert response.meta[:endpoint] == :responses
    end
  end

  describe "stream/2" do
    test "delivers chunks to the collector sink" do
      sink = Aquila.Sink.collector(self())

      {:ok, ref} = Aquila.stream("Stream me", sink: sink, transport: CaptureTransport)

      assert_receive {:aquila_chunk, "chunk", ^ref}
      assert_receive {:aquila_done, "chunk", meta, ^ref}
      assert meta[:status] == :completed
    end
  end

  describe "tool loop" do
    setup do
      Process.put(:capture_test_pid, self())

      on_exit(fn ->
        Process.delete(:capture_test_pid)
        Process.delete(:capture_streams)
        Process.delete(:capture_posts)
      end)

      :ok
    end

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

      Process.put(:capture_streams, [
        [
          %{type: :response_ref, id: "resp_123"},
          %{
            type: :tool_call,
            id: "call_1",
            call_id: "call_1",
            name: "add",
            args_fragment: ~s({"a":2,"b":3})
          },
          %{
            type: :tool_call_end,
            id: "call_1",
            call_id: "call_1",
            name: "add",
            args: %{"a" => 2, "b" => 3}
          },
          %{type: :done, status: :requires_action, meta: %{}}
        ],
        [
          %{type: :delta, content: "Result: 5"},
          %{
            type: :done,
            status: :completed,
            meta: %{tool_calls: [%{name: "add", call_id: "call_1"}]}
          }
        ]
      ])

      response = Aquila.ask("compute", tools: [tool], transport: CaptureTransport)

      assert response.text == "Result: 5"
      assert [%{name: "add", call_id: "call_1"}] = response.meta[:tool_calls]

      assert_receive {:captured, %{body: first_body}}
      refute Map.has_key?(first_body, :tool_outputs)
      assert first_body[:tools] != []

      assert_receive {:captured, %{body: second_body}}
      assert Enum.any?(second_body[:tool_outputs], &(&1[:tool_call_id] == "call_1"))
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

  describe "cassette options" do
    setup do
      Process.put(:capture_test_pid, self())
      on_exit(fn -> Process.delete(:capture_test_pid) end)
      :ok
    end

    test "forwarded to transport opts" do
      aquila_cassette "demo", cassette_index: 4 do
        Aquila.ask("Capture", transport: CaptureTransport)
      end

      assert_receive {:captured, %{opts: opts}}
      assert Keyword.get(opts, :cassette)
      assert Keyword.get(opts, :cassette_index) == 4
    end
  end

  describe "request construction" do
    setup do
      Process.put(:capture_test_pid, self())
      on_exit(fn -> Process.delete(:capture_test_pid) end)
      :ok
    end

    test "chat endpoint includes functions when tools present" do
      tool =
        Tool.new("echo",
          parameters: %{
            type: :object,
            properties: %{text: %{type: :string, required: true}}
          },
          fn: fn %{"text" => text}, _ctx -> %{echo: text} end
        )

      Aquila.ask("Hi", tools: [tool], transport: CaptureTransport, endpoint: :chat)

      assert_receive {:captured, %{endpoint: :chat, body: body}}
      assert body[:functions]
      assert body[:function_call] == "auto"
      assert body[:stream]
    end

    test "normalizes messages option" do
      messages = [
        %{role: :system, content: "System"},
        %{role: :user, content: "Hello"}
      ]

      Aquila.ask([], messages: messages, transport: CaptureTransport, endpoint: :chat)

      assert_receive {:captured, %{body: body}}
      assert Enum.map(body[:messages], & &1[:role]) == ["system", "user"]
    end

    test "normalizes metadata keyword list" do
      Aquila.ask("hi", metadata: [request_id: "abc"], transport: CaptureTransport)

      assert_receive {:captured, %{body: body}}
      assert body[:metadata][:request_id] == "abc"
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
