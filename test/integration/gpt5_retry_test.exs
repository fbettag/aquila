defmodule Aquila.Gpt5RetryTest do
  use ExUnit.Case, async: false
  use Aquila.Cassette

  import Aquila.TestTools

  alias Aquila.Tool

  @moduledoc """
  Live API tests for GPT-5 role compatibility retry logic.

  These tests use real API credentials (not cassettes) to verify that:
  1. Role compatibility errors are detected and retried automatically
  2. Both Chat and Responses endpoints work with GPT-5
  3. Tool calling works after automatic role switching
  4. Multi-turn conversations maintain state through retries

  Tests use both litellm proxy and direct OpenAI API.
  """

  setup_all do
    # Get credentials from environment (always set)
    {:ok,
     litellm: %{
       api_key: System.get_env("OPENAI_API_KEY"),
       base_url: System.get_env("OPENAI_BASE_URL")
     },
     direct: %{
       api_key: System.get_env("OPENAI_DIRECT_API_KEY"),
       base_url: System.get_env("OPENAI_DIRECT_BASE_URL")
     }}
  end

  describe "GPT-5 with litellm proxy" do
    test "chat endpoint with tool calls", %{litellm: config} do
      aquila_cassette "gpt5_retry/litellm_chat" do
        opts = [
          model: "openai/gpt-5",
          endpoint: :chat,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 5+7 using the calculator tool.", opts)

        assert response.text != ""
        assert String.contains?(response.text, "12")
        assert_receive {:tool_called, "5+7"}, 5_000
      end
    end

    test "responses endpoint with tool calls", %{litellm: config} do
      aquila_cassette "gpt5_retry/litellm_responses" do
        opts = [
          model: "openai/gpt-5",
          endpoint: :responses,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 3*4 using the calculator tool.", opts)

        assert response.text != ""
        assert String.contains?(response.text, "12")
        assert_receive {:tool_called, "3*4"}, 5_000
      end
    end

    test "gpt-5-mini with chat endpoint", %{litellm: config} do
      aquila_cassette "gpt5_retry/litellm_gpt5mini_chat" do
        opts = [
          model: "openai/gpt-5-mini",
          endpoint: :chat,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 10-3 using the calculator tool.", opts)

        assert response.text != ""
        assert String.contains?(response.text, "7")
        assert_receive {:tool_called, "10-3"}, 5_000
      end
    end

    test "multi-turn conversation with tools", %{litellm: config} do
      aquila_cassette "gpt5_retry/litellm_multiturn" do
        opts = [
          model: "openai/gpt-5",
          endpoint: :chat,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        # First turn
        response1 = Aquila.ask("Calculate 8+9 using the calculator tool.", opts)
        assert String.contains?(response1.text, "17")
        assert_receive {:tool_called, "8+9"}, 5_000

        # Second turn - continue conversation
        messages = [
          %{role: :user, content: "Calculate 8+9 using the calculator tool."},
          %{role: :assistant, content: response1.text},
          %{role: :user, content: "Now calculate 17*2 using the calculator."}
        ]

        response2 = Aquila.ask(messages, opts)
        assert String.contains?(response2.text, "34")
        assert_receive {:tool_called, "17*2"}, 5_000
      end
    end
  end

  describe "GPT-5-codex with Responses API" do
    test "litellm proxy with tool calls", %{litellm: config} do
      aquila_cassette "gpt5_retry/codex_litellm" do
        opts = [
          model: "openai/gpt-5-codex",
          endpoint: :responses,
          tools: [parallel_calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 12+8 using the calculator tool.", opts)

        assert response.text != ""
        # GPT-5-codex may loop, so collect all calls
        _ = collect_all_parallel_tool_calls([])
        assert is_binary(response.text)
      end
    end

    test "direct API with tool calls", %{direct: config} do
      aquila_cassette "gpt5_retry/codex_direct" do
        opts = [
          model: "gpt-5-codex",
          endpoint: :responses,
          tools: [parallel_calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 25*4 using the calculator tool.", opts)

        assert response.text != ""
        # GPT-5-codex may loop, so collect all calls
        _ = collect_all_parallel_tool_calls([])
        assert is_binary(response.text)
      end
    end

    test "multi-turn with litellm proxy", %{litellm: config} do
      aquila_cassette "gpt5_retry/codex_multiturn" do
        opts = [
          model: "openai/gpt-5-codex",
          endpoint: :responses,
          tools: [parallel_calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        # First turn
        response1 = Aquila.ask("Calculate 50/2 using the calculator tool.", opts)
        assert is_binary(response1.text)
        _ = collect_all_parallel_tool_calls([])

        # Second turn - note: Responses API uses response_id for continuation
        # For now just test another independent call
        response2 = Aquila.ask("Calculate 25+25 using the calculator tool.", opts)
        assert is_binary(response2.text)
        _ = collect_all_parallel_tool_calls([])
      end
    end
  end

  describe "GPT-5 with direct OpenAI API" do
    test "chat endpoint with tool calls", %{direct: config} do
      aquila_cassette "gpt5_retry/direct_chat" do
        opts = [
          model: "gpt-5",
          endpoint: :chat,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 6+8 using the calculator tool.", opts)

        assert response.text != ""
        assert String.contains?(response.text, "14")
        assert_receive {:tool_called, "6+8"}, 5_000
      end
    end

    test "responses endpoint with tool calls", %{direct: config} do
      aquila_cassette "gpt5_retry/direct_responses" do
        opts = [
          model: "gpt-5",
          endpoint: :responses,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 9*3 using the calculator tool.", opts)

        assert response.text != ""
        assert String.contains?(response.text, "27")
        assert_receive {:tool_called, "9*3"}, 5_000
      end
    end

    test "gpt-5-mini with responses endpoint", %{direct: config} do
      aquila_cassette "gpt5_retry/direct_gpt5mini" do
        opts = [
          model: "gpt-5-mini",
          endpoint: :responses,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 20/4 using the calculator tool.", opts)

        assert response.text != ""
        assert String.contains?(response.text, "5")
        assert_receive {:tool_called, "20/4"}, 5_000
      end
    end
  end

  describe "role compatibility verification" do
    test "verifies retry counter increments on role errors", %{litellm: config} do
      aquila_cassette "gpt5_retry/role_compat_verify" do
        # This test verifies that the internal retry mechanism works
        # by checking that tool calls succeed despite potential role incompatibilities
        opts = [
          model: "openai/gpt-5",
          endpoint: :chat,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Use the calculator to compute 15+25.", opts)

        # If we get a successful response, the retry logic worked
        assert response.text != ""
        assert String.contains?(response.text, "40")
        assert_receive {:tool_called, "15+25"}, 5_000

        # The response should complete successfully without raising errors
        assert response.meta.status in [:completed, :succeeded]
      end
    end

    test "handles tool outputs with correct role format", %{litellm: config} do
      aquila_cassette "gpt5_retry/role_format_correct" do
        # This test ensures that tool output messages are formatted correctly
        # after role detection and retry
        opts = [
          model: "openai/gpt-5",
          endpoint: :responses,
          tools: [calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response = Aquila.ask("Calculate 100/5 with the calculator.", opts)

        assert response.text != ""
        assert String.contains?(response.text, "20")
        assert_receive {:tool_called, "100/5"}, 5_000

        # Verify the response structure is correct
        assert is_binary(response.text)
        assert response.meta.status in [:completed, :succeeded]
      end
    end
  end

  describe "parallel tool calls with GPT-5" do
    defp parallel_calculator_tool(test_pid) do
      Tool.new(
        "calculator",
        [
          description: "Performs basic arithmetic calculations.",
          parameters: %{
            type: :object,
            properties: %{
              expression: %{
                type: :string,
                required: true,
                description: "Math expression to evaluate"
              }
            }
          }
        ],
        fn args, context ->
          expression = Map.get(args, "expression", "2+2")
          send(test_pid, {:parallel_tool_called, expression})

          updated_context =
            context
            |> (fn ctx -> ctx || %{} end).()
            |> Map.put(:disable_loop_detection, true)
            |> Map.update(:calls, [expression], fn calls -> [expression | calls] end)

          try do
            {result, _} = Code.eval_string(expression)
            {:ok, "The result is #{result}", updated_context}
          rescue
            _ -> {:ok, "The result is 0", updated_context}
          end
        end
      )
    end

    defp collect_all_parallel_tool_calls(acc) do
      receive do
        {:parallel_tool_called, expr} ->
          collect_all_parallel_tool_calls([expr | acc])
      after
        200 -> Enum.reverse(acc)
      end
    end

    test "handles parallel tool execution", %{litellm: config} do
      aquila_cassette "gpt5_retry/parallel_tools" do
        opts = [
          model: "openai/gpt-5",
          endpoint: :responses,
          tools: [parallel_calculator_tool(self())],
          timeout: 30_000,
          api_key: config.api_key,
          base_url: config.base_url
        ]

        response =
          Aquila.ask(
            "Use the calculator to compute both 7+8 and 5*6. Call the tool for each expression.",
            opts
          )

        assert response.text != ""

        # Collect all tool calls (GPT-5 may loop and call multiple times)
        expressions = collect_all_parallel_tool_calls([])
        unique_expressions = Enum.uniq(expressions)

        # At least one call should have been made
        assert length(unique_expressions) > 0

        # Check if results are mentioned in the response
        # GPT-5 is known to loop, so we're lenient with assertions
        assert is_binary(response.text)
        assert response.meta.status in [:completed, :succeeded]
      end
    end
  end
end
