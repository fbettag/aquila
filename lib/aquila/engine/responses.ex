defmodule Aquila.Engine.Responses do
  @moduledoc """
  Responses API-specific engine implementation.

  Handles:
  - Input/output content part arrays (not message arrays)
  - Tool outputs as function_call_output items in request input
  - Response ID tracking for multi-turn conversations (previous_response_id)
  - Deep research and reasoning support
  - Tool outputs separate from conversation messages
  """

  alias Aquila.Engine.Shared
  alias Aquila.Message

  require Logger

  @behaviour Aquila.Engine.Protocol

  @impl true
  def build_url(%{base_url: base}) do
    trimmed = String.trim_trailing(base, "/")
    trimmed <> "/responses"
  end

  @impl true
  def build_body(state, stream?) do
    # For Responses API, tool outputs are added to the input array as function_call_output items
    input_items = Enum.map(state.messages, &message_to_response/1)

    input_items_with_tool_outputs =
      if state.tool_payloads != [] do
        input_items ++ Enum.map(state.tool_payloads, &tool_payload_to_function_call_output/1)
      else
        input_items
      end

    base = %{
      model: state.model,
      input: input_items_with_tool_outputs,
      stream: stream?
    }

    # Always include tools if available
    base =
      if state.tool_defs != [] do
        Map.put(base, :tools, transform_tools_for_responses_api(state.tool_defs))
      else
        base
      end

    base
    |> Shared.maybe_put(:metadata, metadata_for_request(state))
    |> Shared.maybe_put(:instructions, state.instructions)
    |> Shared.maybe_put(:previous_response_id, state.response_id || state.previous_response_id)
    |> Shared.maybe_put(:reasoning, state.reasoning)
    |> Shared.maybe_put(:store, state.store)
  end

  @impl true
  def append_tool_output_message(_state, messages, _call, _output) do
    # For Responses API, tool outputs are NOT appended to messages
    # They are handled separately via tool_payloads
    messages
  end

  @impl true
  def handle_tool_outputs(state, payloads, _messages, tool_context, tool_outputs, call_history) do
    # For Responses API, update tool_payloads (NOT messages)
    %{
      state
      | tool_payloads: payloads,
        tool_context: tool_context,
        last_tool_outputs: tool_outputs,
        tool_call_history: call_history
    }
  end

  @impl true
  def maybe_append_assistant_tool_call(_state, messages, _call) do
    # For Responses API, we don't append assistant tool call messages
    messages
  end

  @impl true
  def rebuild_tool_messages_for_retry(state, {:format, format}) do
    # Responses API doesn't use tool messages in the same way as Chat
    # Tool outputs are in tool_payloads, not messages
    # So format retry doesn't apply here - just update the format flag
    %{state | tool_message_format: format, error: nil}
  end

  def rebuild_tool_messages_for_retry(state, {:role, use_tool_role}) do
    # Responses API doesn't use function/tool roles the same way
    # But we still track supports_tool_role for consistency
    %{
      state
      | supports_tool_role: use_tool_role,
        error: nil,
        role_retry_count: state.role_retry_count + 1
    }
  end

  ## Private helpers

  defp metadata_for_request(state) do
    case normalize_metadata_for_request(state.metadata) do
      nil ->
        nil

      metadata ->
        if store_enabled?(state.store) do
          metadata
        else
          log_metadata_drop(state, metadata)
          nil
        end
    end
  end

  defp normalize_metadata_for_request(nil), do: nil

  defp normalize_metadata_for_request(%{} = metadata) do
    if map_size(metadata) == 0, do: nil, else: metadata
  end

  defp normalize_metadata_for_request(metadata), do: metadata

  defp store_enabled?(value), do: value in [true, true, "true"]

  defp log_metadata_drop(state, metadata) do
    Logger.warning(
      "Dropping metadata for #{state.model} responses request because :store is not enabled. " <>
        "Set :store to true to persist metadata. Metadata: #{inspect(metadata)}"
    )
  end

  @doc false
  # Transforms function tools to Responses API format.
  # The Responses API expects a flat structure with name/description/parameters at root level:
  #   {"type": "function", "name": "calc", "description": "...", "parameters": {...}}
  #
  # Chat Completions API uses nested structure (for Mistral compatibility):
  #   {"type": "function", "function": {"name": "calc", "description": "...", "parameters": {...}}}
  #
  # This function flattens the nested function object for Responses API compatibility.
  defp transform_tools_for_responses_api(tool_defs) do
    Enum.map(tool_defs, fn tool ->
      # Extract nested function object (could be atom or string key)
      function = Map.get(tool, :function) || Map.get(tool, "function")

      if function do
        # Flatten: move function.name, function.description, function.parameters to root level
        name = Map.get(function, :name) || Map.get(function, "name")
        description = Map.get(function, :description) || Map.get(function, "description")
        parameters = Map.get(function, :parameters) || Map.get(function, "parameters")

        tool
        |> Map.delete(:function)
        |> Map.delete("function")
        |> Shared.maybe_put(:name, name)
        |> Shared.maybe_put(:description, description)
        |> Shared.maybe_put(:parameters, parameters)
      else
        # Non-function tools (e.g., code_interpreter, file_search) pass through unchanged
        tool
      end
    end)
  end

  # Converts tool payload to function_call_output format for Responses API
  defp tool_payload_to_function_call_output(%{call_id: call_id, output: output}) do
    %{
      type: "function_call_output",
      call_id: call_id,
      output: output
    }
  end

  defp message_to_response(%Message{role: role, content: content})
       when is_binary(content) or is_list(content) do
    %{
      role: Atom.to_string(role),
      content: [response_text_part(role, content)]
    }
  end

  defp message_to_response(%Message{role: role, content: content}) when is_map(content) do
    %{
      role: Atom.to_string(role),
      content: [content]
    }
  end

  defp response_text_part(role, content) do
    type =
      case role do
        :assistant -> "output_text"
        :function -> "output_text"
        _ -> "input_text"
      end

    %{type: type, text: IO.iodata_to_binary(content)}
  end
end
