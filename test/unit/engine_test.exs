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
  alias Aquila.Message
  alias Aquila.Tool

  defmodule RoleCompatibilityTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def get(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def delete(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def stream(req, callback) do
      round = Process.get(:role_compat_test_round, 0)
      Process.put(:role_compat_test_round, round + 1)

      # Check if the request contains function or tool role messages
      messages = get_in(req, [:body, :messages]) || []
      has_function_role = Enum.any?(messages, fn msg -> Map.get(msg, :role) == "function" end)

      cond do
        # Round 1: Return tool calls
        round == 0 ->
          callback.(%{
            type: :tool_call,
            id: "calc-1",
            name: "calculator",
            args_fragment: "{\"op\":\"add\",\"x\":5,\"y\":3}",
            call_id: "calc-1"
          })

          callback.(%{
            type: :done,
            status: :requires_action
          })

          {:ok, make_ref()}

        # Round 2: If function role is used, return compatibility error (GPT-5 doesn't support it)
        round == 1 and has_function_role ->
          error_body =
            Jason.encode!(%{
              error: %{
                message:
                  "litellm.BadRequestError: OpenAIException - Unsupported value: 'messages[2].role' does not support 'function' with this model."
              }
            })

          callback.(%{
            type: :error,
            error: {:http_error, 400, error_body}
          })

          {:ok, make_ref()}

        # Round 3: After retry with tool role, return success
        true ->
          callback.(%{type: :delta, content: "8"})
          callback.(%{type: :done, status: :completed})
          {:ok, make_ref()}
      end
    end
  end

  defmodule SilentTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def get(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def delete(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def stream(req, callback) do
      round = Process.get(:silent_round, 0)
      Process.put(:silent_round, round + 1)

      requests = Process.get(:silent_requests, [])
      Process.put(:silent_requests, [req | requests])

      callback.(%{type: :done, status: :completed})
      {:ok, make_ref()}
    end
  end

  defmodule ToolFormatCompatibilityTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def get(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def delete(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def stream(req, callback) do
      round = Process.get(:tool_format_round, 0)
      Process.put(:tool_format_round, round + 1)

      requests = Process.get(:tool_format_requests, [])
      Process.put(:tool_format_requests, [req.body | requests])

      case round do
        0 ->
          callback.(%{
            type: :tool_call,
            id: "calc-1",
            name: "calculator",
            args_fragment: "",
            call_id: "calc-1"
          })

          callback.(%{
            type: :tool_call_end,
            id: "calc-1",
            name: "calculator",
            args: %{"op" => "add", "x" => 5, "y" => 3},
            call_id: "calc-1"
          })

          callback.(%{type: :done, status: :requires_action})
          {:ok, make_ref()}

        1 ->
          {:error,
           {:http_error, 400,
            ~s({"error":{"message":"messages.2.content.1: unexpected `tool_use_id` found in `tool_result` blocks"}})}}

        2 ->
          {:error,
           {:http_error, 400,
            ~s({"error":{"message":"Invalid value: 'tool_result'. Supported values are: 'text', 'image_url', 'input_audio', 'refusal', 'audio', and 'file'."}})}}

        _ ->
          callback.(%{type: :delta, content: "42"})
          callback.(%{type: :done, status: :completed})
          {:ok, make_ref()}
      end
    end
  end

  defmodule EmptyArgsTransport do
    @behaviour Aquila.Transport

    @impl true
    def post(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def get(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def delete(_req), do: {:ok, %{"ok" => true}}

    @impl true
    def stream(req, callback) do
      round = Process.get(:empty_args_round, 0)
      Process.put(:empty_args_round, round + 1)

      requests = Process.get(:empty_args_requests, [])
      Process.put(:empty_args_requests, [req.body | requests])

      case round do
        0 ->
          callback.(%{
            type: :tool_call,
            id: "noop-1",
            name: "noop",
            args_fragment: "",
            call_id: "noop-1"
          })

          callback.(%{
            type: :tool_call_end,
            id: "noop-1",
            name: "noop",
            args: %{},
            call_id: "noop-1"
          })

          callback.(%{type: :done, status: :requires_action})
          {:ok, make_ref()}

        _ ->
          callback.(%{type: :delta, content: "done"})
          callback.(%{type: :done, status: :completed})
          {:ok, make_ref()}
      end
    end
  end

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

  test "automatically retries with tool role when model doesn't support function role" do
    setup = fn ->
      Process.delete(:role_compat_test_round)
    end

    setup.()
    on_exit(setup)

    tool =
      Tool.new(
        "calculator",
        [
          parameters: %{
            "type" => "object",
            "properties" => %{
              "op" => %{"type" => "string"},
              "x" => %{"type" => "number"},
              "y" => %{"type" => "number"}
            }
          }
        ],
        fn %{"op" => "add", "x" => x, "y" => y} -> x + y end
      )

    # Run with Chat Completions endpoint (where role compatibility matters)
    response =
      Engine.run("Calculate 5 + 3",
        transport: RoleCompatibilityTransport,
        tools: [tool],
        endpoint: :chat,
        base_url: "https://api.openai.com/v1",
        model: "openai/gpt-5"
      )

    # Should succeed after automatic retry with tool role
    assert response.text == "8"
    assert response.meta[:status] == :completed

    # Verify that 2 rounds occurred: initial call and retry with the supported tool role format
    assert Process.get(:role_compat_test_round) == 2
  end

  test "forces tool execution when provider completes without tool calls" do
    cleanup = fn ->
      Process.delete(:silent_round)
      Process.delete(:silent_requests)
    end

    cleanup.()
    on_exit(cleanup)

    tool =
      Tool.new(
        "calculator",
        [parameters: %{"type" => "object", "properties" => %{}}],
        fn _args ->
          send(self(), :forced_tool_invoked)
          "42"
        end
      )

    response =
      Engine.run("Please add 2+2", transport: SilentTransport, tools: [tool], endpoint: :chat)

    assert response.meta[:status] == :completed
    assert_received :forced_tool_invoked
    assert Process.get(:silent_round) == 2
  end

  test "retries tool message format when provider flips between tool_result and text" do
    cleanup = fn ->
      Process.delete(:tool_format_round)
      Process.delete(:tool_format_requests)
    end

    cleanup.()
    on_exit(cleanup)

    tool =
      Tool.new(
        "calculator",
        [
          parameters: %{
            "type" => "object",
            "properties" => %{
              "op" => %{"type" => "string"},
              "x" => %{"type" => "number"},
              "y" => %{"type" => "number"}
            }
          }
        ],
        fn args ->
          send(self(), {:tool_args_seen, args})
          "42"
        end
      )

    response =
      Engine.run("Calculate 5 + 3",
        transport: ToolFormatCompatibilityTransport,
        tools: [tool],
        endpoint: :chat,
        model: "openai/gpt-4o"
      )

    assert response.text == "42"
    assert response.meta[:status] == :completed
    assert_receive {:tool_args_seen, %{"op" => "add", "x" => 5, "y" => 3}}
    assert Process.get(:tool_format_round) == 4

    requests =
      Process.get(:tool_format_requests, [])
      |> Enum.reverse()
      |> Enum.map(& &1.messages)

    assert length(requests) == 4

    [req_initial, req_tool_text, req_tool_structured, req_tool_final] = requests

    assert Enum.map(req_initial, & &1.role) == ["user"]

    assert Enum.map(req_tool_text, & &1.role) == ["user", "assistant", "tool"]
    tool_call = Enum.at(req_tool_text, 1)
    assert length(tool_call.tool_calls) == 1
    tool_message_text = Enum.at(req_tool_text, 2)
    assert is_binary(tool_message_text.content)

    assert Enum.map(req_tool_structured, & &1.role) == ["user", "assistant", "tool"]
    structured_content = Enum.at(req_tool_structured, 2).content
    assert is_list(structured_content)
    [%{"type" => "tool_result", "content" => [%{"text" => "42"}]}] = structured_content

    assert Enum.map(req_tool_final, & &1.role) == ["user", "assistant", "tool"]
    final_content = Enum.at(req_tool_final, 2).content
    assert is_binary(final_content)
  end

  test "engine includes assistant tool call even when arguments are empty" do
    cleanup = fn ->
      Process.delete(:empty_args_requests)
      Process.delete(:empty_args_round)
    end

    cleanup.()
    on_exit(cleanup)

    tool = Tool.new("noop", fn _args -> "done" end)

    response =
      Engine.run("Ping",
        transport: EmptyArgsTransport,
        tools: [tool],
        endpoint: :chat,
        model: "openai/gpt-4.1"
      )

    assert response.text == "done"

    requests =
      Process.get(:empty_args_requests, [])
      |> Enum.reverse()
      |> Enum.map(& &1.messages)

    assert length(requests) >= 2

    second_request = Enum.at(requests, 1)

    assistant_with_tool =
      Enum.find(second_request, fn msg ->
        Map.get(msg, :role) == "assistant" and is_list(Map.get(msg, :tool_calls))
      end)

    refute assistant_with_tool == nil

    [tool_call] = Map.get(assistant_with_tool, :tool_calls)
    assert tool_call["id"] == "noop-1"
    assert get_in(tool_call, ["function", "arguments"]) == "{}"

    tool_message =
      Enum.find(second_request, fn msg ->
        Map.get(msg, :role) == "tool"
      end)

    refute tool_message == nil
    assert Map.get(tool_message, :tool_call_id) == "noop-1"
  end

  test "Message module supports both tool and function roles" do
    # Verify tool role message creation
    tool_msg = Message.tool_output_message("test_tool", "tool output", tool_call_id: "call-123")
    assert tool_msg.role == :tool
    assert tool_msg.tool_call_id == "call-123"
    assert tool_msg.name == "test_tool"
    assert tool_msg.content == "tool output"

    # Verify function role message creation (legacy format)
    func_msg = Message.function_message("test_func", "function output")
    assert func_msg.role == :function
    assert func_msg.tool_call_id == nil
    assert func_msg.name == "test_func"
    assert func_msg.content == "function output"

    # Verify to_chat_map includes tool_call_id for tool role
    tool_map = Message.to_chat_map(tool_msg)
    assert tool_map.role == "tool"
    assert tool_map.tool_call_id == "call-123"

    # Verify to_chat_map doesn't include tool_call_id for function role
    func_map = Message.to_chat_map(func_msg)
    assert func_map.role == "function"
    refute Map.has_key?(func_map, :tool_call_id)
  end
end
