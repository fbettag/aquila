defmodule Aquila.Engine.Shared do
  @moduledoc """
  Shared functionality between Chat and Responses engine implementations.

  Contains endpoint-agnostic logic for:
  - Tool execution and loop detection
  - State management and configuration
  - Event handling (shared parts)
  - Telemetry emissions
  - Error detection and retry logic
  """

  alias Aquila.Sink
  alias Aquila.Tool

  require Logger

  @builtin_tools ~w(code_interpreter file_search web_search_preview)a
  @builtin_tool_strings Enum.map(@builtin_tools, &Atom.to_string/1)

  ## Configuration and state helpers

  @doc "Reads application configuration for :aquila :openai key"
  def config(key) do
    :aquila |> Application.get_env(:openai, []) |> Keyword.get(key)
  end

  @doc "Resolves API key from {:system, var} tuples or direct strings"
  def resolve_api_key({:system, var}) when is_binary(var), do: System.get_env(var)
  def resolve_api_key(key) when is_binary(key), do: key
  def resolve_api_key(_), do: nil

  @doc "Normalizes metadata option to map"
  def normalize_metadata(nil), do: %{}
  def normalize_metadata(map) when is_map(map), do: map
  def normalize_metadata(list) when is_list(list), do: Map.new(list)
  def normalize_metadata(_), do: %{}

  @doc "Normalizes reasoning option"
  def normalize_reasoning(nil), do: nil
  def normalize_reasoning(reasoning) when is_map(reasoning), do: reasoning

  def normalize_reasoning(reasoning) when is_binary(reasoning) do
    %{effort: String.downcase(reasoning)}
  end

  def normalize_reasoning(_), do: nil

  ## Tool normalization and management

  @doc "Normalizes tools list into Tool structs or builtin tool maps"
  def normalize_tools(list) do
    Enum.map(list, &normalize_tool/1)
  end

  defp normalize_tool(%Tool{} = tool), do: tool

  defp normalize_tool(%{name: name, parameters: parameters} = map) do
    function = Map.get(map, :function) || Map.get(map, :fun) || Map.fetch!(map, :fn)
    Tool.new(name, [description: Map.get(map, :description), parameters: parameters], function)
  end

  defp normalize_tool(%{"name" => name, "parameters" => parameters} = map) do
    function = Map.get(map, "function") || Map.get(map, "fun") || Map.fetch!(map, "fn")
    Tool.new(name, [description: Map.get(map, "description"), parameters: parameters], function)
  end

  defp normalize_tool(%{type: type} = map) when is_atom(type) or is_binary(type) do
    %{map | type: builtin_type!(type)}
  end

  defp normalize_tool(%{"type" => type} = map) when is_atom(type) or is_binary(type) do
    Map.put(map, "type", builtin_type!(type))
  end

  defp normalize_tool(type) when is_atom(type) or is_binary(type) do
    %{type: builtin_type!(type)}
  end

  defp normalize_tool(other) do
    raise ArgumentError, "invalid tool: #{inspect(other)}"
  end

  defp builtin_type!(type) when is_atom(type) do
    type |> Atom.to_string() |> builtin_type!()
  end

  defp builtin_type!(type) when is_binary(type) do
    if type in @builtin_tool_strings do
      type
    else
      raise ArgumentError, "unknown built-in tool: #{inspect(type)}"
    end
  end

  @doc "Builds map of tool name => Tool struct for quick lookup"
  def build_tool_map(tools) do
    tools
    |> Enum.filter(&match?(%Tool{}, &1))
    |> Map.new(&{&1.name, &1})
  end

  ## Tool execution

  @doc """
  Invokes a tool function and normalizes the result.

  Returns {status, value, context_patch} tuple.
  Emits telemetry and sink events for tool execution.
  """
  def invoke_tool(state, call, messages, endpoint_impl) do
    tool = Map.get(state.tool_map, call.name)

    unless tool do
      raise ArgumentError, "no tool registered for #{call.name}"
    end

    args = call.args || parse_args(call.args_fragment)

    # Emit tool call event before execution
    Sink.notify(
      state.sink,
      {:event, %{type: :tool_call_start, name: call.name, args: args, id: call.id}},
      state.ref
    )

    start = System.monotonic_time()

    {status, value, context_patch} =
      try do
        invoke_tool_function(tool.function, args, state.tool_context)
      rescue
        exception ->
          Logger.warning("Tool #{call.name} raised", exception: Exception.message(exception))
          Sink.notify(state.sink, {:error, %{tool: call.name, error: exception}}, state.ref)
          reraise(exception, __STACKTRACE__)
      end

    if status == :error do
      Logger.warning("Tool returned error", tool: call.name, reason: value)
    end

    duration = System.monotonic_time() - start

    :telemetry.execute([:aquila, :tool, :invoke], %{duration: duration}, %{
      name: call.name,
      model: state.model
    })

    output = normalize_tool_output(value)
    new_context = merge_tool_context(state.tool_context, context_patch)

    payload = %{id: call.id, call_id: call.call_id || call.id, name: call.name, output: output}

    # Emit tool call completion event with result
    event_payload =
      %{type: :tool_call_result, name: call.name, args: args, output: output, id: call.id}
      |> Map.put(:status, status)
      |> maybe_put(:context, new_context)
      |> maybe_put(:context_patch, empty_map_to_nil(context_patch))

    Sink.notify(
      state.sink,
      {:event, event_payload},
      state.ref
    )

    new_messages = endpoint_impl.append_tool_output_message(state, messages, call, output)

    {payload, new_messages, new_context, status}
  end

  defp invoke_tool_function(function, args, context) when is_function(function, 2) do
    safe_tool_invoke(fn -> function.(args, context) end)
  end

  defp invoke_tool_function(function, args, _context) when is_function(function, 1) do
    safe_tool_invoke(fn -> function.(args) end)
  end

  defp safe_tool_invoke(fun) do
    normalize_tool_result(fun.())
  rescue
    exception ->
      normalize_tool_result({:exception, exception, __STACKTRACE__})
  end

  defp normalize_tool_result({:ok, value}) do
    {:ok, normalize_success_value(value), %{}}
  end

  defp normalize_tool_result({:ok, value, context}) do
    {:ok, normalize_success_value(value), ensure_context_map(context)}
  end

  defp normalize_tool_result({:error, reason}) do
    {:error, normalize_error_value(reason), %{}}
  end

  defp normalize_tool_result({:error, reason, context}) do
    {:error, normalize_error_value(reason), ensure_context_map(context)}
  end

  defp normalize_tool_result({:exception, exception, stacktrace}) do
    formatted = Exception.format(:error, exception, stacktrace)
    sanitized = sanitize_exception_message(formatted)
    {:error, error_payload("Exception raised", sanitized), %{}}
  end

  defp normalize_tool_result({value, _bindings}) do
    normalize_tool_result(value)
  end

  defp normalize_tool_result(value) do
    {:ok, normalize_success_value(value), %{}}
  end

  defp normalize_success_value(value) when is_struct(value) do
    if ecto_changeset?(value) do
      error_payload("Validation failed", format_changeset_errors(value))
    else
      inspect(value)
    end
  end

  defp normalize_success_value(value) when is_binary(value), do: value
  defp normalize_success_value(value) when is_map(value), do: value
  defp normalize_success_value(value), do: value

  defp normalize_error_value(reason) do
    error_payload("Operation failed", reason)
  end

  defp ensure_context_map(nil), do: %{}
  defp ensure_context_map(map) when is_map(map), do: map

  defp ensure_context_map(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword) do
      Map.new(keyword)
    else
      raise ArgumentError, "tool context patch must be a map, got: #{inspect(keyword)}"
    end
  end

  defp ensure_context_map(other) do
    raise ArgumentError, "tool context patch must be a map, got: #{inspect(other)}"
  end

  defp error_payload(header, reason) do
    [header, render_reason(reason)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp render_reason(reason) do
    cond do
      ecto_changeset?(reason) -> format_changeset_errors(reason)
      is_binary(reason) -> reason
      is_struct(reason) -> inspect(reason)
      is_map(reason) -> inspect(reason)
      is_list(reason) -> inspect(reason)
      true -> inspect(reason)
    end
  end

  defp ecto_changeset?(%{__struct__: struct}) do
    ecto_changeset_module = Module.concat(Ecto, Changeset)
    struct == ecto_changeset_module and Code.ensure_loaded?(ecto_changeset_module)
  rescue
    ArgumentError -> false
  end

  defp ecto_changeset?(_), do: false

  defp format_changeset_errors(changeset) do
    module = Module.concat(Ecto, Changeset)

    if Code.ensure_loaded?(module) and function_exported?(module, :traverse_errors, 2) do
      errors =
        module.traverse_errors(changeset, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", format_changeset_value(value))
          end)
        end)

      if Enum.empty?(errors) do
        inspect(changeset)
      else
        Enum.map_join(errors, "\n", fn {field, messages} ->
          field_name =
            field
            |> to_string()
            |> String.replace("_", " ")
            |> String.trim()
            |> String.capitalize()

          formatted_messages = messages |> List.wrap() |> Enum.map_join(", ", &to_string/1)

          "#{field_name}: #{formatted_messages}"
        end)
      end
    else
      inspect(changeset)
    end
  end

  defp format_changeset_value(value) when is_binary(value), do: value
  defp format_changeset_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_changeset_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_changeset_value(value) when is_float(value), do: Float.to_string(value)

  defp format_changeset_value({:array, type}) do
    "array of #{format_changeset_value(type)}"
  end

  defp format_changeset_value(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map_join(" ", &format_changeset_value/1)
  end

  defp format_changeset_value(value), do: inspect(value)

  @doc """
  Sanitizes exception messages to remove non-deterministic elements like PIDs,
  user IDs, timestamps, email addresses, and test-generated names/slugs.
  This ensures cassette stability when exceptions occur during testing.
  """
  def sanitize_exception_message(message) when is_binary(message) do
    message
    |> String.replace(~r/#PID<\d+\.\d+\.\d+>/, "#PID<0.0.0>")
    |> String.replace(~r/user-\d+@example\.com/, "user-N@example.com")
    |> String.replace(~r/id: \d+/, "id: N")
    |> String.replace(~r/~N\[[^\]]+\]/, "~N[TIMESTAMP]")
    |> String.replace(~r/#Reference<[^>]+>/, "#Reference<REDACTED>")
    |> String.replace(~r/name: "org\d+"/, "name: \"orgN\"")
    |> String.replace(~r/slug: "org\d+"/, "slug: \"orgN\"")
  end

  def sanitize_exception_message(message), do: message

  defp parse_args(nil), do: %{}

  defp parse_args(fragment) when is_binary(fragment) do
    case Jason.decode(fragment) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, "invalid tool args: #{inspect(error)}"
    end
  end

  @doc "Normalizes tool output to string or JSON-encoded format"
  def normalize_tool_output(output) when is_binary(output), do: output

  def normalize_tool_output(output) when is_map(output) do
    Jason.encode!(output)
  end

  def normalize_tool_output(other) do
    Jason.encode!(%{result: other})
  end

  @doc "Merges tool context patch into current context"
  def merge_tool_context(current, patch) when patch == %{}, do: current
  def merge_tool_context(nil, patch), do: patch

  def merge_tool_context(current, patch) when is_map(current) do
    Map.merge(current, patch, fn _key, _old, new -> new end)
  end

  def merge_tool_context(current, patch) when is_list(current) do
    if Keyword.keyword?(current) do
      current
      |> Map.new()
      |> Map.merge(patch, fn _key, _old, new -> new end)
    else
      patch
    end
  end

  def merge_tool_context(_current, patch), do: patch

  ## Tool call tracking (for streaming)

  @doc "Tracks accumulating tool call fragments during streaming"
  def track_tool_call(calls, %{id: id} = event) do
    {before, rest} = Enum.split_while(calls, &(&1.id != id))

    updated =
      case rest do
        [%{args_fragment: fragment} = call | tail] ->
          new_fragment = fragment <> (Map.get(event, :args_fragment, "") || "")

          new_call =
            call
            |> Map.put(:args_fragment, new_fragment)
            |> maybe_put(:call_id, Map.get(event, :call_id))
            |> maybe_put(:name, Map.get(event, :name))

          before ++ [new_call | tail]

        [] ->
          call = %{
            id: id,
            name: Map.get(event, :name),
            args_fragment: Map.get(event, :args_fragment, "") || "",
            call_id: Map.get(event, :call_id),
            status: :collecting
          }

          calls ++ [call]
      end

    updated
  end

  @doc "Finalizes a specific tool call by parsing its accumulated fragments"
  def finalize_tool_call(calls, %{id: id} = event) do
    Enum.map(calls, fn
      %{id: ^id} = call ->
        args = Map.get(event, :args) || parse_args(call.args_fragment)

        call
        |> Map.put(:args, args)
        |> maybe_put(:call_id, Map.get(event, :call_id))
        |> Map.put(:status, :ready)

      other ->
        other
    end)
  end

  @doc "Finalizes all collecting tool calls (used when finish_reason indicates requires_action)"
  def finalize_all_collecting_calls(calls) do
    Enum.map(calls, fn
      %{status: :collecting, args_fragment: fragment} = call when fragment != "" ->
        args = parse_args(fragment)

        call
        |> Map.put(:args, args)
        |> Map.put(:status, :ready)

      %{status: :collecting} = call ->
        # Empty args fragment, use empty map
        call
        |> Map.put(:args, %{})
        |> Map.put(:status, :ready)

      other ->
        other
    end)
  end

  @doc "Appends tool call metadata to final_meta"
  def append_tool_meta(meta, ready_calls) do
    tool_info = Enum.map(ready_calls, &Map.take(&1, [:id, :name, :call_id]))
    Map.update(meta, :tool_calls, tool_info, fn existing -> existing ++ tool_info end)
  end

  ## Telemetry

  @doc "Emits telemetry start event"
  def emit_start(%{telemetry: %{meta: meta}}) do
    :telemetry.execute([:aquila, :stream, :start], %{system_time: System.system_time()}, meta)
  end

  @doc "Emits telemetry stop event"
  def emit_stop(%{telemetry: %{start_time: start, meta: meta}}, status) do
    duration = System.monotonic_time() - start

    :telemetry.execute(
      [:aquila, :stream, :stop],
      %{duration: duration},
      Map.put(meta, :status, status)
    )
  end

  @doc "Emits telemetry chunk event"
  def emit_chunk(%{telemetry: %{meta: meta}}, size) do
    :telemetry.execute([:aquila, :stream, :chunk], %{size: size}, meta)
  end

  ## Error detection

  @doc """
  Detects if an error is due to tool message format incompatibility.
  Returns {:retry, new_state} or :no_retry.
  """
  def detect_tool_message_format_error(error, state) do
    message = extract_error_message(error)

    cond do
      requires_structured_tool_result?(message) and state.tool_message_format != :tool_result ->
        {:retry, state}

      rejects_structured_tool_result?(message) and state.tool_message_format == :tool_result ->
        {:retry, state}

      true ->
        :no_retry
    end
  end

  @doc """
  Detects if an error is due to role compatibility and determines if we should retry.
  Returns {:retry, new_state} if we should retry with a different role format,
  or :no_retry if this is a different error or we've already tried both formats.
  """
  def detect_role_compatibility_error(error, state) do
    error_message = extract_error_message(error)

    cond do
      # Error indicates 'tool' role is not supported and we haven't tried function role yet
      role_not_supported?(error_message, "tool") and state.supports_tool_role != false ->
        Logger.debug("Model does not support 'tool' role, switching to 'function' role")
        {:retry, state}

      # Error indicates 'function' role is not supported and we haven't tried tool role yet
      role_not_supported?(error_message, "function") and state.supports_tool_role != true ->
        Logger.debug("Model does not support 'function' role, switching to 'tool' role")
        {:retry, state}

      # Either not a role error, or we've already tried both formats
      true ->
        :no_retry
    end
  end

  # Extracts error message string from various error formats
  defp extract_error_message({:http_error, _code, body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> msg
      _ -> body
    end
  end

  defp extract_error_message(%{message: msg}) when is_binary(msg), do: msg
  defp extract_error_message(error) when is_binary(error), do: error
  defp extract_error_message(_), do: ""

  # Checks if error message indicates a specific role is not supported
  @doc false
  def role_not_supported?(message, role) do
    cond do
      # Generic patterns for both roles
      String.contains?(message, "'#{role}'") and String.contains?(message, "does not support") ->
        true

      String.contains?(message, "Unsupported value") ->
        true

      String.contains?(message, "unknown variant `#{role}`") ->
        true

      # Tool role specific errors
      role == "tool" and String.contains?(message, "unexpected `tool_use_id`") ->
        true

      role == "tool" and
          (String.contains?(
             message,
             "must be a response to a preceeding message with 'tool_calls'"
           ) or
             String.contains?(
               message,
               "must be a response to a preceding message with 'tool_calls'"
             )) ->
        true

      # Function role specific errors
      role == "function" and String.contains?(message, "unsupported role ROLE_FUNCTION") ->
        true

      role == "function" and String.contains?(message, "unknown role ROLE_FUNCTION") ->
        true

      true ->
        false
    end
  end

  @doc false
  def extract_tool_call_args(call) do
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

  defp requires_structured_tool_result?(message) do
    String.contains?(message, "unexpected `tool_use_id`") or
      String.contains?(message, "must have a corresponding `tool_use` block") or
      String.contains?(message, "tool_call_id  is not found") or
      String.contains?(message, "tool_call_id is not found") or
      String.contains?(message, "must be a response to a preceding message with 'tool_calls'") or
      String.contains?(message, "must be a response to a preceeding message with 'tool_calls'")
  end

  defp rejects_structured_tool_result?(message) do
    String.contains?(message, "Invalid value: 'tool_result'")
  end

  ## Utility functions

  @doc "Conditionally puts value in map if not nil"
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  defp empty_map_to_nil(%{} = map) when map_size(map) == 0, do: nil
  defp empty_map_to_nil(other), do: other
end
