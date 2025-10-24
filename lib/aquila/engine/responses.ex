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

        # Determine if tool has optional parameters
        # If it does, we need to explicitly set strict: false to prevent the API from
        # automatically making all parameters required
        strict = should_use_strict_mode?(parameters)

        tool
        |> Map.delete(:function)
        |> Map.delete("function")
        |> Shared.maybe_put(:name, name)
        |> Shared.maybe_put(:description, description)
        |> Shared.maybe_put(:parameters, parameters)
        |> Shared.maybe_put(:strict, strict)
      else
        # Non-function tools (e.g., code_interpreter, file_search) pass through unchanged
        tool
      end
    end)
  end

  # Determines if a tool should use strict mode based on its parameters.
  # If a tool has optional parameters (properties not in the required array),
  # we must explicitly set strict: false. Otherwise, the Responses API will
  # automatically enable strict mode and make ALL properties required.
  defp should_use_strict_mode?(nil), do: nil

  defp should_use_strict_mode?(%{} = params) do
    properties = Map.get(params, "properties") || Map.get(params, :properties) || %{}
    required = Map.get(params, "required") || Map.get(params, :required) || []

    property_names =
      properties
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    required_names =
      required
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    # If there are properties that are NOT in the required array, we have optional params
    has_optional_params = not MapSet.subset?(property_names, required_names)

    # Return false for strict mode if there are optional params, otherwise nil (let API decide)
    if has_optional_params do
      false
    else
      nil
    end
  end

  defp should_use_strict_mode?(_), do: nil

  # Converts tool payload to function_call_output format for Responses API
  defp tool_payload_to_function_call_output(%{call_id: call_id, output: output}) do
    %{
      type: "function_call_output",
      call_id: call_id,
      output: output
    }
  end

  # Handle content parts (list of maps) - pass through directly
  defp message_to_response(%Message{role: role, content: content})
       when is_list(content) do
    if content_parts?(content) do
      %{
        role: Atom.to_string(role),
        content: normalize_content_parts(content, role)
      }
    else
      # iodata - convert to single text part
      %{
        role: Atom.to_string(role),
        content: [response_text_part(role, content)]
      }
    end
  end

  # Handle binary content
  defp message_to_response(%Message{role: role, content: content})
       when is_binary(content) do
    %{
      role: Atom.to_string(role),
      content: [response_text_part(role, content)]
    }
  end

  # Handle single content part map
  defp message_to_response(%Message{role: role, content: content}) when is_map(content) do
    %{
      role: Atom.to_string(role),
      content: [normalize_content_part(content, role)]
    }
  end

  # Helper to detect if list contains content parts (maps) vs iodata (strings/binaries)
  defp content_parts?([]), do: false
  defp content_parts?([%{} | _]), do: true
  defp content_parts?(_), do: false

  defp normalize_content_parts(parts, role) do
    Enum.map(parts, &normalize_content_part(&1, role))
  end

  defp normalize_content_part(%{"type" => "text"} = part, role) do
    Map.put(part, "type", content_type_for_role(role))
  end

  defp normalize_content_part(%{type: "text"} = part, role) do
    Map.put(part, :type, content_type_for_role(role))
  end

  # Normalize common content types to Responses API format
  # Supported types: input_text, input_image, output_text, refusal, input_file, computer_screenshot, summary_text

  defp normalize_content_part(%{"type" => "file", "file" => file_obj} = part, _role) do
    # Responses API supports both URLs and base64 data:
    # - For URLs: {"type": "input_file", "file_url": "https://..."}
    # - For base64: {"type": "input_file", "file_data": "base64...", "filename": "doc.pdf"}

    file_data_or_url = Map.get(file_obj, "file_data", "") || Map.get(file_obj, "file_id", "")

    cond do
      # Handle URLs (starts with http/https)
      String.starts_with?(file_data_or_url, ["http://", "https://"]) ->
        part
        |> Map.put("type", "input_file")
        |> Map.put("file_url", file_data_or_url)
        |> Map.delete("file")

      # Handle base64 data URLs
      String.contains?(file_data_or_url, ";base64,") ->
        # Keep the full data URL format - the API expects: "data:media/type;base64,ACTUALBASE64"
        # Use actual filename if provided, otherwise generate a reasonable default
        filename = Map.get(file_obj, "filename") || infer_filename(file_obj)

        part
        |> Map.put("type", "input_file")
        |> Map.put("file_data", file_data_or_url)
        |> Map.put("filename", filename)
        |> Map.delete("file")

      # Fallback: treat as base64 data
      true ->
        filename = Map.get(file_obj, "filename") || infer_filename(file_obj)

        part
        |> Map.put("type", "input_file")
        |> Map.put("file_data", file_data_or_url)
        |> Map.put("filename", filename)
        |> Map.delete("file")
    end
  end

  defp normalize_content_part(%{type: "file", file: file_obj} = part, _role) do
    # Responses API supports both URLs and base64 data:
    # - For URLs: {type: "input_file", file_url: "https://..."}
    # - For base64: {type: "input_file", file_data: "base64...", filename: "doc.pdf"}

    file_data_or_url = Map.get(file_obj, :file_data, "") || Map.get(file_obj, :file_id, "")

    cond do
      # Handle URLs (starts with http/https)
      String.starts_with?(file_data_or_url, ["http://", "https://"]) ->
        part
        |> Map.put(:type, "input_file")
        |> Map.put(:file_url, file_data_or_url)
        |> Map.delete(:file)

      # Handle base64 data URLs
      String.contains?(file_data_or_url, ";base64,") ->
        # Keep the full data URL format - the API expects: "data:media/type;base64,ACTUALBASE64"
        # Use actual filename if provided, otherwise generate a reasonable default
        filename = Map.get(file_obj, :filename) || infer_filename(file_obj)

        part
        |> Map.put(:type, "input_file")
        |> Map.put(:file_data, file_data_or_url)
        |> Map.put(:filename, filename)
        |> Map.delete(:file)

      # Fallback: treat as base64 data
      true ->
        filename = Map.get(file_obj, :filename) || infer_filename(file_obj)

        part
        |> Map.put(:type, "input_file")
        |> Map.put(:file_data, file_data_or_url)
        |> Map.put(:filename, filename)
        |> Map.delete(:file)
    end
  end

  defp normalize_content_part(%{"type" => "image"} = part, _role) do
    Map.put(part, "type", "input_image")
  end

  defp normalize_content_part(%{type: "image"} = part, _role) do
    Map.put(part, :type, "input_image")
  end

  defp normalize_content_part(%{"type" => "image_url", "image_url" => image_url} = part, _role)
       when is_map(image_url) do
    # Keep the image_url structure as-is (supports both URLs and data URLs)
    Map.put(part, "type", "input_image")
  end

  defp normalize_content_part(%{type: "image_url", image_url: image_url} = part, _role)
       when is_map(image_url) do
    # Keep the image_url structure as-is (supports both URLs and data URLs)
    Map.put(part, :type, "input_image")
  end

  defp normalize_content_part(part, _role), do: part

  # Infer a reasonable filename from the file object's format/media type
  defp infer_filename(file_obj) when is_map(file_obj) do
    format =
      Map.get(file_obj, "format") || Map.get(file_obj, :format) || "application/octet-stream"

    case format do
      "application/pdf" -> "document.pdf"
      "text/plain" -> "document.txt"
      "application/msword" -> "document.doc"
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "document.docx"
      "text/csv" -> "document.csv"
      "application/json" -> "document.json"
      _ -> "document.bin"
    end
  end

  defp content_type_for_role(:assistant), do: "output_text"
  defp content_type_for_role(:function), do: "output_text"
  defp content_type_for_role(_role), do: "input_text"

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
