defmodule Aquila.EngineSharedTest do
  use ExUnit.Case, async: true

  alias Aquila.Engine.Shared
  alias Aquila.Sink
  alias Aquila.Tool

  defmodule FakeEndpoint do
    def append_tool_output_message(_state, messages, call, output) do
      messages ++ [%{call: call, output: output}]
    end
  end

  describe "detect_role_compatibility_error/2" do
    test "retries with function role when tool role is unsupported" do
      state = %{supports_tool_role: nil}
      error_body = ~s({"error":{"message":"Model does not support 'tool' role"}})

      assert {:retry, ^state} =
               Shared.detect_role_compatibility_error({:http_error, 400, error_body}, state)
    end

    test "retries with tool role when function role is unsupported" do
      state = %{supports_tool_role: nil}

      assert {:retry, ^state} =
               Shared.detect_role_compatibility_error(
                 %{message: "unknown variant `function`"},
                 state
               )
    end

    test "does not retry when role incompatibility already known" do
      state = %{supports_tool_role: false}

      assert :no_retry =
               Shared.detect_role_compatibility_error(
                 %{message: "does not support 'tool' role"},
                 state
               )
    end
  end

  describe "extract_tool_call_args/1" do
    test "returns existing args map when present" do
      call = %{args: %{"value" => 1}}

      assert %{"value" => 1} = Shared.extract_tool_call_args(call)
    end

    test "decodes args fragment into map" do
      call = %{args_fragment: "{\"foo\": 1}"}

      assert %{"foo" => 1} = Shared.extract_tool_call_args(call)
    end

    test "returns empty map when fragment cannot be decoded" do
      call = %{args_fragment: "{invalid"}

      assert %{} == Shared.extract_tool_call_args(call)
    end
  end

  describe "normalize_metadata/1" do
    test "returns empty map for nil" do
      assert %{} == Shared.normalize_metadata(nil)
    end

    test "coerces keyword list into map" do
      assert %{foo: "bar"} == Shared.normalize_metadata(foo: "bar")
    end

    test "ignores unsupported metadata types" do
      assert %{} == Shared.normalize_metadata("nope")
    end
  end

  describe "normalize_reasoning/1" do
    test "downcases binary effort hint" do
      assert %{effort: "low"} == Shared.normalize_reasoning("LOW")
    end

    test "passes through map" do
      reasoning = %{effort: "medium"}
      assert reasoning == Shared.normalize_reasoning(reasoning)
    end

    test "returns nil for unsupported type" do
      assert Shared.normalize_reasoning(123) == nil
    end
  end

  describe "normalize_tools/1" do
    test "converts maps into Tool structs" do
      tool_def = %{
        name: "calc",
        description: "adds numbers",
        parameters: %{"type" => "object"},
        fn: fn _ -> :ok end
      }

      [tool] = Shared.normalize_tools([tool_def])
      assert %Tool{name: "calc", description: "adds numbers"} = tool
    end

    test "normalizes builtin atom tools" do
      [%{type: "code_interpreter"}] = Shared.normalize_tools([:code_interpreter])
    end

    test "accepts string-keyed tool definitions" do
      tool_def = %{
        "name" => "calc",
        "parameters" => %{"type" => "object"},
        "fn" => fn _ -> :ok end
      }

      [tool] = Shared.normalize_tools([tool_def])
      assert %Tool{name: "calc"} = tool
    end
  end

  describe "role_not_supported?/2" do
    test "detects tool role incompatibility" do
      assert Shared.role_not_supported?("Model does not support 'tool' role", "tool")
      assert Shared.role_not_supported?("unexpected `tool_use_id` value", "tool")
    end

    test "detects function role incompatibility" do
      assert Shared.role_not_supported?("unknown variant `function`", "function")
    end

    test "ignores unrelated messages" do
      refute Shared.role_not_supported?("all good", "tool")
    end
  end

  describe "normalize_tool_output/1" do
    test "passes through binary" do
      assert "ok" == Shared.normalize_tool_output("ok")
    end

    test "encodes map as JSON" do
      result = Shared.normalize_tool_output(%{"foo" => "bar"})
      assert %{"foo" => "bar"} == Jason.decode!(result)
    end

    test "wraps other terms under result key" do
      result = Shared.normalize_tool_output(42)
      assert %{"result" => 42} == Jason.decode!(result)
    end
  end

  describe "merge_tool_context/2" do
    test "merges maps preferring new values" do
      assert %{foo: 2} == Shared.merge_tool_context(%{foo: 1}, %{foo: 2})
    end

    test "coerces keyword lists to map" do
      assert %{foo: :bar} == Shared.merge_tool_context([foo: :old], %{foo: :bar})
    end

    test "defaults nil current to patch" do
      patch = %{foo: :bar}
      assert patch == Shared.merge_tool_context(nil, patch)
    end

    test "returns patch when current context unsupported" do
      patch = %{foo: :bar}
      assert patch == Shared.merge_tool_context("not a map", patch)
    end
  end

  describe "tool call tracking" do
    test "track_tool_call appends new call" do
      calls =
        Shared.track_tool_call([], %{
          id: "call-1",
          name: "calc",
          args_fragment: "{\"x\":",
          call_id: nil
        })

      assert [%{id: "call-1", args_fragment: "{\"x\":", status: :collecting}] = calls
    end

    test "track_tool_call accumulates fragments" do
      initial =
        Shared.track_tool_call([], %{
          id: "call-1",
          name: "calc",
          args_fragment: "{\"x\":",
          call_id: nil
        })

      updated =
        Shared.track_tool_call(initial, %{
          id: "call-1",
          args_fragment: "1}",
          call_id: "call-1"
        })

      assert [%{args_fragment: "{\"x\":1}", call_id: "call-1"}] = updated
    end

    test "finalize_tool_call parses accumulated fragment" do
      calls = [
        %{id: "call-1", args_fragment: "{\"x\":1}", status: :collecting}
      ]

      finalized = Shared.finalize_tool_call(calls, %{id: "call-1"})

      assert [%{args: %{"x" => 1}, status: :ready}] = finalized
    end

    test "finalize_all_collecting_calls handles empty fragments" do
      calls = [
        %{id: "call-1", args_fragment: "{\"x\":1}", status: :collecting},
        %{id: "call-2", args_fragment: "", status: :collecting}
      ]

      finalized = Shared.finalize_all_collecting_calls(calls)

      assert [
               %{id: "call-1", args: %{"x" => 1}, status: :ready},
               %{id: "call-2", args: %{}, status: :ready}
             ] = finalized
    end
  end

  describe "append_tool_meta/2" do
    test "appends ready call metadata" do
      meta = %{tool_calls: [%{id: "existing"}]}
      ready = [%{id: "a", name: "calc", call_id: "1"}]

      result = Shared.append_tool_meta(meta, ready)

      assert [
               %{id: "existing"},
               %{id: "a", name: "calc", call_id: "1"}
             ] = result.tool_calls
    end
  end

  describe "detect_tool_message_format_error/2" do
    test "retries when structured result required" do
      error = {:http_error, 400, ~s({"error":{"message":"unexpected `tool_use_id`"}})}
      state = %{tool_message_format: :text}

      assert {:retry, ^state} = Shared.detect_tool_message_format_error(error, state)
    end

    test "retries when structured result rejected" do
      error = %{message: "Invalid value: 'tool_result'"}
      state = %{tool_message_format: :tool_result}

      assert {:retry, ^state} = Shared.detect_tool_message_format_error(error, state)
    end

    test "skips retry for unrelated error" do
      state = %{tool_message_format: :text}
      assert :no_retry = Shared.detect_tool_message_format_error("other", state)
    end
  end

  describe "sanitize_exception_message/1" do
    test "redacts unstable tokens" do
      message =
        "Error #PID<1.2.3> user-42@example.com id: 123 ~N[2024-01-01 00:00:00] #Reference<abc> name: \"org1\" slug: \"org2\""

      sanitized = Shared.sanitize_exception_message(message)

      refute sanitized =~ "1.2.3"
      assert sanitized =~ "#PID<0.0.0>"
      assert sanitized =~ "user-N@example.com"
      assert sanitized =~ "id: N"
      assert sanitized =~ "~N[TIMESTAMP]"
      assert sanitized =~ "#Reference<REDACTED>"
      assert sanitized =~ "name: \"orgN\""
      assert sanitized =~ "slug: \"orgN\""
    end
  end

  describe "config helpers" do
    test "fetches config and resolves system env key" do
      original = Application.get_env(:aquila, :openai)
      on_exit(fn -> Application.put_env(:aquila, :openai, original) end)

      Application.put_env(:aquila, :openai, api_key: "123")

      assert Shared.config(:api_key) == "123"

      System.put_env("AQUILA_TEST_KEY", "from_env")
      on_exit(fn -> System.delete_env("AQUILA_TEST_KEY") end)

      assert Shared.resolve_api_key({:system, "AQUILA_TEST_KEY"}) == "from_env"
      assert Shared.resolve_api_key("direct") == "direct"
      assert Shared.resolve_api_key(:invalid) == nil
    end
  end

  describe "tool call finalization" do
    test "finalize_tool_call prefers explicit args" do
      calls = [%{id: "call-1", args_fragment: "{}", status: :collecting}]
      finalized = Shared.finalize_tool_call(calls, %{id: "call-1", args: %{"explicit" => true}})

      assert [%{args: %{"explicit" => true}, status: :ready}] = finalized
    end
  end

  describe "invoke_tool/4" do
    test "invokes tool and emits events" do
      tool =
        Tool.new("echo", [parameters: %{"type" => "object"}], fn args, context ->
          {:ok, Map.put(args, "context", context), %{context: :updated}}
        end)

      state = %{
        tool_map: %{"echo" => tool},
        tool_context: %{context: :initial},
        sink: Sink.pid(self()),
        ref: make_ref(),
        model: "gpt-test"
      }

      call = %{name: "echo", id: "call-1", call_id: "call-1", args: %{"value" => 1}}

      {payload, new_messages, new_context, status} =
        Shared.invoke_tool(state, call, [], FakeEndpoint)

      assert payload.output == ~s({"context":{"context":"initial"},"value":1})
      assert new_context == %{context: :updated}
      assert status == :ok
      assert [%{output: output}] = new_messages
      assert output == payload.output

      assert_receive {:aquila_tool_call, :start, %{type: :tool_call_start}, _ref}
      assert_receive {:aquila_tool_call, :result, %{type: :tool_call_result}, _ref}
    end

    test "handles tool error tuple" do
      tool =
        Tool.new("fails", [parameters: %{"type" => "object"}], fn _args -> {:error, "nope"} end)

      state = %{
        tool_map: %{"fails" => tool},
        tool_context: %{},
        sink: Sink.pid(self()),
        ref: make_ref(),
        model: "gpt-test"
      }

      call = %{name: "fails", id: "call-err", call_id: "call-err", args: %{}}

      {payload, _messages, context, status} = Shared.invoke_tool(state, call, [], FakeEndpoint)

      assert payload.output =~ "Operation failed"
      assert context == %{}
      assert status == :error
    end
  end
end
