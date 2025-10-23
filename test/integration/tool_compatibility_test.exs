defmodule Aquila.ToolCompatibilityTest do
  use ExUnit.Case, async: true
  use Aquila.Cassette

  import Aquila.TestTools

  alias Aquila.Tool

  @moduledoc """
  Comprehensive tool compatibility testing across different model providers.
  Tests ensure custom function tools are properly serialized for each provider.
  Uses live API calls with cassette recording.

  Note: Built-in tools (code_interpreter, file_search, etc.) are OpenAI-specific
  and not supported by most providers via litellm. Users can pass raw tool maps
  for provider-specific features if needed.
  """

  @models [
    "openai/gpt-3.5-turbo",
    "openai/gpt-4o",
    "openai/gpt-4o-mini",
    "openai/gpt-4.1-mini",
    "openai/gpt-4.1",
    "openai/gpt-5-mini",
    "openai/gpt-5",
    "openai/gpt-5-codex",
    "openai/o3-mini",
    "anthropic/claude-3-5-sonnet-latest",
    "anthropic/claude-3-opus-latest",
    "anthropic/claude-sonnet-4-5",
    "anthropic/claude-haiku-4-5",
    "mistral/mistral-medium",
    "moonshot/kimi-latest",
    "deepseek/deepseek-chat",
    "xai/grok-3-mini-latest",
    "xai/grok-4-fast-non-reasoning"
  ]

  @direct_openai_models [
    "gpt-4.1-mini",
    "gpt-4.1",
    "gpt-5-mini",
    "gpt-5",
    "gpt-5-codex",
    "o3-mini"
  ]

  @parallel_litellm_models [
    "openai/gpt-5",
    "openai/o3-mini"
  ]

  @parallel_direct_models [
    "gpt-5",
    "o3-mini"
  ]

  @retry_litellm_models [
    "openai/gpt-5"
  ]

  @retry_direct_models [
    "gpt-5"
  ]

  defp sanitize_model(model) do
    model
    |> String.replace("/", "_")
    |> String.replace(".", "_")
    |> String.replace("-", "_")
  end

  defp cassette_path(provider, model, endpoint, scenario) do
    base =
      case provider do
        :direct_openai -> "tool_compat/openai_direct"
        _ -> "tool_compat"
      end

    scenario_segment =
      case scenario do
        :custom_function -> "custom_function"
        :parallel_calls -> "parallel_calls"
        :retry_tool -> "retry_tool"
        other -> to_string(other)
      end

    "#{base}/#{sanitize_model(model)}/#{endpoint}/#{scenario_segment}"
  end

  defp ensure_context(nil), do: %{}
  defp ensure_context(context) when is_map(context), do: context
  defp ensure_context(_other), do: %{}

  # Pre-compute model-endpoint pairs at compile time for test generation
  @parallel_litellm_tests for model <- @parallel_litellm_models,
                              endpoint <-
                                (cond do
                                   String.contains?(model, "gpt-5-codex") -> [:responses]
                                   String.starts_with?(model, "openai/o") -> [:responses]
                                   String.starts_with?(model, "openai/") -> [:chat, :responses]
                                   true -> [:chat]
                                 end),
                              do: {model, endpoint}

  @parallel_direct_tests for model <- @parallel_direct_models,
                             endpoint <-
                               (cond do
                                  String.contains?(model, "gpt-5-codex") -> [:responses]
                                  String.starts_with?(model, "o") -> [:responses]
                                  true -> [:chat, :responses]
                                end),
                             do: {model, endpoint}

  @retry_litellm_tests for model <- @retry_litellm_models,
                           endpoint <-
                             (cond do
                                String.contains?(model, "gpt-5-codex") -> [:responses]
                                String.starts_with?(model, "openai/o") -> [:responses]
                                String.starts_with?(model, "openai/") -> [:chat, :responses]
                                true -> [:chat]
                              end),
                           do: {model, endpoint}

  @retry_direct_tests for model <- @retry_direct_models,
                          endpoint <-
                            (cond do
                               String.contains?(model, "gpt-5-codex") -> [:responses]
                               String.starts_with?(model, "o") -> [:responses]
                               true -> [:chat, :responses]
                             end),
                          do: {model, endpoint}

  @compatibility_tests for model <- @models,
                           endpoint <-
                             (cond do
                                String.contains?(model, "gpt-5-codex") -> [:responses]
                                String.starts_with?(model, "openai/o") -> [:responses]
                                String.starts_with?(model, "openai/") -> [:chat, :responses]
                                String.starts_with?(model, "o") -> [:responses]
                                true -> [:chat]
                              end),
                           do: {model, endpoint}

  @direct_compatibility_tests for model <- @direct_openai_models,
                                  endpoint <-
                                    (cond do
                                       String.contains?(model, "gpt-5-codex") -> [:responses]
                                       String.starts_with?(model, "o") -> [:responses]
                                       true -> [:chat, :responses]
                                     end),
                                  do: {model, endpoint}

  defp parallel_calculator_tool(test_pid) do
    Tool.new(
      "calculator",
      [
        description: "Performs arithmetic calculations and supports concurrent requests.",
        parameters: %{
          type: :object,
          properties: %{
            expression: %{
              type: :string,
              required: true,
              description: "Math expression to evaluate (e.g., '2+2', '3+3')"
            }
          }
        }
      ],
      fn args, context ->
        expression = Map.get(args, "expression", "2+2")
        send(test_pid, {:parallel_tool_called, expression})

        updated_context =
          context
          |> ensure_context()
          |> Map.put(:disable_loop_detection, true)
          |> update_in([:calls], fn calls -> [expression | List.wrap(calls)] end)

        try do
          {result, _} = Code.eval_string(expression)
          {:ok, "The result is #{result}", updated_context}
        rescue
          _ -> {:ok, "The result is 0", updated_context}
        end
      end
    )
  end

  defp flaky_calculator_tool(test_pid) do
    Tool.new(
      "flaky_calculator",
      [
        description:
          "A calculator that may fail once before succeeding. Retry if an error is returned.",
        parameters: %{
          type: :object,
          properties: %{
            expression: %{
              type: :string,
              required: true,
              description: "Math expression to evaluate (e.g., '2+2', '10*5')"
            }
          }
        }
      ],
      fn args, context ->
        ctx = ensure_context(context)
        attempt = Map.get(ctx, :attempt, 0) + 1
        expression = Map.get(args, "expression", "2+2")
        send(test_pid, {:flaky_tool_called, attempt, expression})

        new_ctx =
          ctx
          |> Map.put(:disable_loop_detection, true)
          |> Map.put(:attempt, attempt)
          |> update_in([:calls], fn calls -> [expression | List.wrap(calls)] end)

        if attempt == 1 do
          {:error, "transient failure", new_ctx}
        else
          try do
            {result, _} = Code.eval_string(expression)
            {:ok, "The result is #{result}", new_ctx}
          rescue
            _ -> {:ok, "The result is 0", new_ctx}
          end
        end
      end
    )
  end

  # Helper to collect all tool call messages from mailbox
  # Models may loop and call tools multiple times before completing
  defp collect_all_tool_calls(acc) do
    receive do
      {:parallel_tool_called, expr} ->
        collect_all_tool_calls([expr | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  describe "parallel tool call compatibility" do
    for {model, endpoint} <- @parallel_litellm_tests do
      test "#{model} handles parallel tool calls (#{endpoint})" do
        model = unquote(model)
        endpoint = unquote(endpoint)

        aquila_cassette cassette_path(:litellm, model, endpoint, :parallel_calls) do
          opts = [
            model: model,
            tools: [parallel_calculator_tool(self())],
            timeout: 30_000,
            endpoint: endpoint
          ]

          response =
            Aquila.ask(
              "Use the calculator tool to compute 2+2 and 3+3. Call the tool for each expression (parallel if supported) and report both results.",
              opts
            )

          assert response.text != ""
          assert String.contains?(response.text, "4")
          assert String.contains?(response.text, "6")

          # Collect all tool call messages - model may loop and call tools multiple times
          expressions = collect_all_tool_calls([])

          # Verify both expressions were called at least once (allow duplicates due to looping)
          unique_expressions = Enum.uniq(expressions)

          assert Enum.sort(unique_expressions) == Enum.sort(["2+2", "3+3"]),
                 "Expected both '2+2' and '3+3' to be called, got: #{inspect(unique_expressions)}"
        end
      end
    end

    for {model, endpoint} <- @parallel_direct_tests do
      test "#{model} handles parallel tool calls via direct API (#{endpoint})" do
        config = direct_openai_config!()
        model = unquote(model)
        endpoint = unquote(endpoint)

        aquila_cassette cassette_path(:direct_openai, model, endpoint, :parallel_calls) do
          opts = [
            model: model,
            tools: [parallel_calculator_tool(self())],
            timeout: 30_000,
            endpoint: endpoint,
            base_url: config.base_url,
            api_key: config.api_key
          ]

          response =
            Aquila.ask(
              "Use the calculator tool to compute 2+2 and 3+3. Call the tool for each expression (parallel if supported) and report both results.",
              opts
            )

          assert response.text != ""
          assert String.contains?(response.text, "4")
          assert String.contains?(response.text, "6")

          # Collect all tool call messages - model may loop and call tools multiple times
          expressions = collect_all_tool_calls([])

          # Verify both expressions were called at least once (allow duplicates due to looping)
          unique_expressions = Enum.uniq(expressions)

          assert Enum.sort(unique_expressions) == Enum.sort(["2+2", "3+3"]),
                 "Expected both '2+2' and '3+3' to be called, got: #{inspect(unique_expressions)}"
        end
      end
    end
  end

  describe "tool retry compatibility" do
    for {model, endpoint} <- @retry_litellm_tests do
      test "#{model} retries tool calls after transient failure (#{endpoint})" do
        model = unquote(model)
        endpoint = unquote(endpoint)

        aquila_cassette cassette_path(:litellm, model, endpoint, :retry_tool) do
          opts = [
            model: model,
            tools: [flaky_calculator_tool(self())],
            timeout: 30_000,
            endpoint: endpoint
          ]

          response =
            Aquila.ask(
              "Use the flaky calculator tool to compute 2+2. If the tool reports an error, try again until it succeeds and then return the answer.",
              opts
            )

          assert_receive {:flaky_tool_called, 1, expr1}, 5_000
          assert expr1 == "2+2"
          assert_receive {:flaky_tool_called, 2, expr2}, 5_000
          assert expr2 == "2+2"
          refute_receive {:flaky_tool_called, _, _}, 200

          assert response.text != ""
          assert String.contains?(response.text, "4")
        end
      end
    end

    for {model, endpoint} <- @retry_direct_tests do
      test "#{model} retries tool calls after transient failure via direct API (#{endpoint})" do
        config = direct_openai_config!()
        model = unquote(model)
        endpoint = unquote(endpoint)

        aquila_cassette cassette_path(:direct_openai, model, endpoint, :retry_tool) do
          opts = [
            model: model,
            tools: [flaky_calculator_tool(self())],
            timeout: 30_000,
            endpoint: endpoint,
            base_url: config.base_url,
            api_key: config.api_key
          ]

          response =
            Aquila.ask(
              "Use the flaky calculator tool to compute 2+2. If the tool reports an error, try again until it succeeds and then return the answer.",
              opts
            )

          assert_receive {:flaky_tool_called, 1, expr1}, 5_000
          assert expr1 == "2+2"
          assert_receive {:flaky_tool_called, 2, expr2}, 5_000
          assert expr2 == "2+2"
          refute_receive {:flaky_tool_called, _, _}, 200

          assert response.text != ""
          assert String.contains?(response.text, "4")
        end
      end
    end
  end

  describe "custom function tool compatibility" do
    for {model, endpoint} <- @compatibility_tests do
      test "#{model} accepts and calls custom function tool (#{endpoint})" do
        model = unquote(model)
        endpoint = unquote(endpoint)

        aquila_cassette cassette_path(:litellm, model, endpoint, :custom_function) do
          opts = [
            model: model,
            tools: [calculator_tool(self())],
            timeout: 30_000,
            endpoint: endpoint
          ]

          response =
            Aquila.ask(
              "Please calculate 2+2 using the calculator tool. You must use the calculator tool to answer this.",
              opts
            )

          # Verify the model provided a response
          assert response.text != ""

          # Verify the tool was actually called
          assert_receive {:tool_called, expression},
                         5000,
                         "Expected calculator tool to be called by #{model}, but it was not invoked"

          # The expression should be related to the calculation
          assert is_binary(expression), "Expected expression to be a string"
        end
      end
    end
  end

  describe "direct OpenAI custom function tool compatibility" do
    for {model, endpoint} <- @direct_compatibility_tests do
      test "#{model} accepts and calls custom function tool via direct API (#{endpoint})" do
        config = direct_openai_config!()
        model = unquote(model)
        endpoint = unquote(endpoint)

        aquila_cassette cassette_path(
                          :direct_openai,
                          model,
                          endpoint,
                          :custom_function
                        ) do
          opts = [
            model: model,
            tools: [calculator_tool(self())],
            timeout: 30_000,
            endpoint: endpoint,
            base_url: config.base_url,
            api_key: config.api_key
          ]

          response =
            Aquila.ask(
              "Please calculate 2+2 using the calculator tool. You must use the calculator tool to answer this.",
              opts
            )

          assert response.text != ""

          assert_receive {:tool_called, expression},
                         5000,
                         "Expected calculator tool to be called by #{model} (direct), but it was not invoked"

          assert is_binary(expression), "Expected expression to be a string"
        end
      end
    end
  end

  defp direct_openai_config! do
    api_key =
      System.get_env("OPENAI_DIRECT_API_KEY") ||
        System.get_env("DIRECT_OPENAI_API_KEY") ||
        System.get_env("OPENAI_API_KEY_DIRECT")

    base_url =
      System.get_env("OPENAI_DIRECT_BASE_URL") ||
        System.get_env("DIRECT_OPENAI_BASE_URL") ||
        "https://api.openai.com/v1"

    cond do
      api_key in [nil, ""] ->
        raise """
        Direct OpenAI credentials missing.

        Export OPENAI_DIRECT_API_KEY (or DIRECT_OPENAI_API_KEY / OPENAI_API_KEY_DIRECT) \
        and rerun the test suite. Optionally set OPENAI_DIRECT_BASE_URL when targeting a non-default endpoint.
        """

      true ->
        %{api_key: api_key, base_url: base_url}
    end
  end
end
