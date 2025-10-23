defmodule Aquila.Engine.Chat do
  @moduledoc """
  Chat Completions API-specific engine implementation.

  Handles:
  - Message array format with system/user/assistant/function/tool roles
  - Tool outputs as function or tool role messages appended to conversation
  - GPT-5 role compatibility detection and retry
  - Multi-turn conversations via message history
  """

  alias Aquila.Engine.Shared
  alias Aquila.Message

  require Logger

  @behaviour Aquila.Engine.Protocol

  @impl true
  def build_url(%{base_url: base}) do
    trimmed = String.trim_trailing(base, "/")
    trimmed <> "/chat/completions"
  end

  @impl true
  def build_body(state, stream?) do
    # Convert instructions to system message for Chat Completions API
    messages =
      if state.instructions do
        [Message.new(:system, state.instructions) | state.messages]
      else
        state.messages
      end

    base = %{
      model: state.model,
      messages: Enum.map(messages, &Message.to_chat_map/1),
      stream: stream?
    }

    base =
      if state.tool_defs == [] do
        base
      else
        base
        |> Map.put(:tools, state.tool_defs)
        |> Map.put(:tool_choice, encode_tool_choice(state.tool_choice))
      end

    Shared.maybe_put(base, :metadata, metadata_for_request(state))
  end

  @impl true
  def append_tool_output_message(state, messages, call, output) do
    messages ++ [create_tool_output_message(state, call, output)]
  end

  @impl true
  def handle_tool_outputs(state, _payloads, messages, tool_context, tool_outputs, call_history) do
    # For Chat API, tool outputs are appended as messages (already done in append_tool_output_message)
    # Return updated messages, not payloads
    %{
      state
      | messages: messages,
        tool_context: tool_context,
        last_tool_outputs: tool_outputs,
        tool_call_history: call_history
    }
  end

  @impl true
  def maybe_append_assistant_tool_call(_state, messages, call) do
    append_assistant_tool_call_message(messages, call)
  end

  @impl true
  def rebuild_tool_messages_for_retry(state, format_or_role_flag) do
    case format_or_role_flag do
      # Tool message format retry
      {:format, format} ->
        updated_state = %{state | tool_message_format: format, error: nil}
        rebuild_messages_with_format(updated_state)

      # Role compatibility retry
      {:role, use_tool_role} ->
        rebuild_messages_with_different_role(state, use_tool_role)
    end
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
      "Dropping metadata for #{state.model} chat request because :store is not enabled. " <>
        "Set :store to true to persist metadata. Metadata: #{inspect(metadata)}"
    )
  end

  # Creates a tool output message, using the appropriate role based on model capabilities.
  # Tries tool role first (newer format), falls back to function role if needed.
  defp create_tool_output_message(state, call, output) do
    tool_output_message_for_state(state, call.name, call.call_id || call.id, output)
  end

  defp tool_output_message_for_state(state, name, call_id, output) do
    if should_use_tool_role?(state) do
      Message.tool_output_message(
        name,
        output,
        tool_call_id: call_id,
        format: tool_message_format(state)
      )
    else
      Message.function_message(name, output)
    end
  end

  defp append_assistant_tool_call_message(messages, call) do
    call_id = call.call_id || call.id

    already_present =
      Enum.any?(messages, fn
        %Message{role: :assistant, tool_calls: tool_calls} when is_list(tool_calls) ->
          Enum.any?(tool_calls, &tool_call_matches?(&1, call_id))

        _ ->
          false
      end)

    args_map = extract_tool_call_args(call)

    if already_present do
      messages
    else
      entry = %{
        "id" => call_id,
        "type" => "function",
        "function" => %{
          "name" => call.name,
          "arguments" => encode_tool_arguments(args_map)
        }
      }

      messages ++ [Message.new(:assistant, "", tool_calls: [entry])]
    end
  end

  defp tool_call_matches?(%{"id" => id}, call_id), do: id == call_id
  defp tool_call_matches?(%{id: id}, call_id), do: id == call_id
  defp tool_call_matches?(_, _), do: false

  defp encode_tool_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_tool_arguments(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp encode_tool_arguments(_), do: "{}"

  defp extract_tool_call_args(call) do
    cond do
      is_map(call[:args]) and map_size(call[:args]) > 0 ->
        call.args

      is_binary(call[:args_fragment]) ->
        fragment = String.trim(call.args_fragment)

        if fragment != "" and fragment != "{}" do
          case Jason.decode(fragment) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end
        else
          %{}
        end

      true ->
        %{}
    end
  end

  # Rebuilds messages with a different tool role format after detecting incompatibility.
  # This removes tool output messages and recreates them with the specified role format.
  defp rebuild_messages_with_different_role(state, use_tool_role) do
    # Update the state to remember which format to use and increment retry counter
    updated_state = %{
      state
      | supports_tool_role: use_tool_role,
        error: nil,
        role_retry_count: state.role_retry_count + 1
    }

    # Remove tool output messages (function or tool role) that were added in the last round
    cleaned_messages =
      Enum.reject(updated_state.messages, fn msg ->
        msg.role in [:function, :tool]
      end)

    # Recreate tool output messages with the new format using stored outputs
    new_tool_messages =
      Enum.map(updated_state.last_tool_outputs, fn %{call_id: call_id, name: name, output: output} ->
        tool_output_message_for_state(updated_state, name, call_id, output)
      end)

    rebuilt_messages = cleaned_messages ++ new_tool_messages

    %{updated_state | messages: rebuilt_messages}
  end

  defp rebuild_messages_with_format(state) do
    cleaned_messages =
      Enum.reject(state.messages, fn msg ->
        msg.role in [:function, :tool]
      end)

    new_tool_messages =
      Enum.map(state.last_tool_outputs, fn %{call_id: call_id, name: name, output: output} ->
        tool_output_message_for_state(state, name, call_id, output)
      end)

    %{state | messages: cleaned_messages ++ new_tool_messages}
  end

  defp tool_message_format(%{tool_message_format: format})
       when format in [:text, :tool_result],
       do: format

  defp tool_message_format(_), do: :text

  # Determines whether to use the 'tool' role based on detection state.
  # Defaults to the newer tool role unless we've already proven it fails.
  defp should_use_tool_role?(%{supports_tool_role: nil}), do: true
  # Known to work
  defp should_use_tool_role?(%{supports_tool_role: true}), do: true
  # Known to fail
  defp should_use_tool_role?(%{supports_tool_role: false}), do: false

  defp encode_tool_choice(:auto), do: "auto"
  defp encode_tool_choice(:required), do: "required"

  defp encode_tool_choice({:function, name}) when is_binary(name) do
    %{"type" => "function", "function" => %{"name" => name}}
  end

  defp encode_tool_choice({:function, name}) when is_atom(name) do
    encode_tool_choice({:function, Atom.to_string(name)})
  end

  defp encode_tool_choice(%{} = choice), do: choice
  defp encode_tool_choice(value) when is_binary(value), do: value
  defp encode_tool_choice(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_tool_choice(_), do: "auto"
end
