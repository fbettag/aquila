defmodule Aquila.Engine do
  @moduledoc """
  Internal orchestration loop that normalises prompts, manages streaming
  callbacks, drives tool execution, and hydrates `%Aquila.Response{}`
  structures. The module intentionally prefers the Responses API but will fall
  back to Chat Completions when necessary, keeping cassette recording and sink
  notifications consistent across transports.

  While `Aquila.Engine` is not part of the public API, guides refer to it to
  explain how prompts flow through transports, sinks, and tool invocations.
  """

  alias Aquila.Endpoint
  alias Aquila.Message
  alias Aquila.Response
  alias Aquila.Sink
  alias Aquila.Tool

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :endpoint,
      :transport,
      :base_url,
      :api_key,
      :model,
      :metadata,
      :instructions,
      :reasoning,
      :sink,
      :stream?,
      :ref,
      :timeout,
      :cassette,
      :cassette_index,
      :store,
      messages: [],
      tools: [],
      tool_defs: [],
      tool_map: %{},
      tool_payloads: [],
      pending_calls: [],
      acc_chunks: [],
      raw_events: [],
      tool_context: nil,
      response_id: nil,
      previous_response_id: nil,
      status: :in_progress,
      final_meta: %{},
      usage: %{},
      round: 0,
      telemetry: %{start_time: nil, meta: %{}},
      error: nil,
      supports_tool_role: nil,
      tool_message_format: :text,
      tool_choice: :auto,
      tool_choice_forced?: false,
      last_tool_outputs: [],
      tool_call_history: [],
      role_retry_count: 0
    ]
  end

  @type input :: iodata() | [Message.t()]

  @spec run(input(), keyword()) :: Response.t() | {:ok, reference()} | {:error, term()}
  def run(input, opts) do
    stream? = Keyword.get(opts, :stream, false)
    state = build_state(input, opts, stream?)

    if state.stream? do
      start_stream(state)
    else
      {_state, response} = run_pipeline(state)
      response
    end
  end

  defp build_state(input, opts, stream?) do
    transport =
      Keyword.get(opts, :transport) ||
        Application.get_env(:aquila, :transport, Aquila.Transport.OpenAI)

    tools = normalize_tools(Keyword.get(opts, :tools, []))
    model = opts[:model] || config(:default_model) || "gpt-4o-mini"
    reasoning = normalize_reasoning(opts[:reasoning])
    base_url = opts[:base_url] || config(:base_url) || "https://api.openai.com/v1"

    endpoint =
      opts
      |> Keyword.merge(base_url: base_url, model: model)
      |> Endpoint.choose()
      |> select_reasoning_endpoint(reasoning)

    sink = Keyword.get(opts, :sink, if(stream?, do: Sink.pid(self()), else: :ignore))
    metadata = normalize_metadata(opts[:metadata])
    timeout = opts[:timeout] || config(:request_timeout) || 30_000
    api_key = resolve_api_key(opts[:api_key] || config(:api_key))
    messages = normalize_input(input, opts)
    tool_defs = Enum.map(tools, &Tool.to_openai/1)
    tool_map = build_tool_map(tools)
    ref = Keyword.get(opts, :ref, make_ref())
    cassette = Keyword.get(opts, :cassette)
    cassette_index = Keyword.get(opts, :cassette_index)
    instructions = opts[:instructions] || opts[:instruction]
    previous_response_id = opts[:previous_response_id] || opts[:response_id]
    store = Keyword.get(opts, :store)
    tool_context = Keyword.get(opts, :tool_context)
    tool_choice = normalize_tool_choice(Keyword.get(opts, :tool_choice, :auto))

    telemetry_meta = %{endpoint: endpoint, model: to_string(model), stream?: stream?}
    telemetry = %{start_time: System.monotonic_time(), meta: telemetry_meta}

    %State{
      endpoint: endpoint,
      transport: transport,
      base_url: base_url,
      api_key: api_key,
      model: to_string(model),
      metadata: metadata,
      instructions: instructions,
      reasoning: reasoning,
      sink: sink,
      stream?: stream?,
      ref: ref,
      timeout: timeout,
      cassette: cassette,
      cassette_index: cassette_index,
      store: store,
      messages: messages,
      tools: tools,
      tool_defs: tool_defs,
      tool_map: tool_map,
      tool_context: tool_context,
      tool_choice: tool_choice,
      previous_response_id: previous_response_id,
      telemetry: telemetry
    }
  end

  defp start_stream(%State{} = state) do
    ref = state.ref

    task =
      Task.async(fn ->
        try do
          {_final, response} = run_pipeline(%{state | stream?: true})
          Sink.notify(state.sink, {:done, response.text, response.meta}, ref)
          {:ok, response}
        rescue
          exception ->
            Sink.notify(state.sink, {:error, %{exception: exception}}, ref)
            reraise(exception, __STACKTRACE__)
        end
      end)

    # Store task reference so caller can await if needed
    Process.put({:aquila_stream_task, ref}, task)

    {:ok, ref}
  end

  defp run_pipeline(%State{} = state) do
    emit_start(state)

    try do
      final_state = loop(state)
      response = build_response(final_state)
      emit_stop(final_state, :ok)
      {final_state, response}
    rescue
      exception ->
        emit_stop(state, {:error, exception})
        reraise(exception, __STACKTRACE__)
    end
  end

  defp loop(%State{} = state) do
    state = %{state | round: state.round + 1}
    state = do_stream(state)

    cond do
      ready_tool_calls?(state) ->
        state
        |> execute_tools()
        |> loop()

      match?(%{error: error} when not is_nil(error), state) ->
        raise_error(state, state.error)

      state.status in [:completed, :succeeded, :done] ->
        state

      state.status == :requires_action ->
        # Tools requested but not ready yet - this shouldn't happen since
        # tool_call_end events should have made them ready, but handle gracefully
        state

      true ->
        state
    end
  end

  defp do_stream(%State{} = state) do
    key = {:aquila_engine_state, state.ref}
    Process.put(key, %{state | pending_calls: [], error: nil})
    req = build_request(state)

    result = state.transport.stream(req, fn event -> process_event(key, event) end)
    new_state = Process.delete(key)

    case result do
      {:ok, _ref} ->
        %{new_state | tool_payloads: []}

      {:error, reason} ->
        current_state = new_state || state
        %{current_state | error: reason}
    end
  end

  defp process_event(key, event) do
    state = Process.get(key)
    new_state = handle_event(state, event)
    Process.put(key, new_state)
    :ok
  end

  defp handle_event(%State{} = state, %{type: :delta, content: content} = event) do
    chunk = IO.iodata_to_binary(content)

    # Check if this is a duplicate final delta (contains all accumulated text)
    # Some APIs send incremental deltas followed by a final complete delta
    accumulated_text = state.acc_chunks |> Enum.reverse() |> IO.iodata_to_binary()

    should_skip =
      accumulated_text != "" and chunk == accumulated_text

    if should_skip do
      # Skip this duplicate final delta
      Logger.debug("Skipping duplicate final delta")
      %{state | raw_events: [event | state.raw_events]}
    else
      maybe_notify_chunk(state, chunk)
      emit_chunk(state, byte_size(chunk))
      %{state | raw_events: [event | state.raw_events], acc_chunks: [chunk | state.acc_chunks]}
    end
  end

  defp handle_event(%State{} = state, %{type: :message, content: content})
       when is_binary(content) do
    handle_event(state, %{type: :delta, content: content})
  end

  defp handle_event(%State{} = state, %{type: :response_ref, id: id} = event) do
    %{state | response_id: id, raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :usage, usage: usage} = event) do
    merged = Map.merge(state.usage, usage, fn _k, v1, v2 -> merge_usage_value(v1, v2) end)
    maybe_notify_event(state, %{type: :usage, usage: usage})
    %{state | usage: merged, raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :tool_call, id: id} = event) when not is_nil(id) do
    pending = track_tool_call(state.pending_calls, event)
    %{state | pending_calls: pending, raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :tool_call} = event) do
    # Skip tool_call events with null id - they're malformed
    %{state | raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :tool_call_end} = event) do
    pending = finalize_tool_call(state.pending_calls, event)
    %{state | pending_calls: pending, raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :done} = event) do
    status = Map.get(event, :status, :completed)
    meta = event |> Map.get(:meta, %{}) |> normalize_meta()

    # When finish_reason indicates tool calls, ensure all collecting calls are finalized
    state =
      if status == :requires_action do
        %{state | pending_calls: finalize_all_collecting_calls(state.pending_calls)}
      else
        state
      end

    final_meta =
      if meta && meta != %{} do
        Map.merge(state.final_meta, meta)
      else
        state.final_meta
      end

    %{
      state
      | status: status,
        final_meta: final_meta,
        raw_events: [event | state.raw_events]
    }
  end

  defp handle_event(%State{} = state, %{type: :event} = event) do
    payload = Map.get(event, :payload, Map.drop(event, [:type]))
    maybe_notify_event(state, payload)
    %{state | raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :error, error: error} = event) do
    Sink.notify(state.sink, {:error, error}, state.ref)
    %{state | error: error, raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, event) when is_map(event) do
    %{state | raw_events: [event | state.raw_events]}
  end

  defp merge_usage_value(v1, v2) when is_number(v1) and is_number(v2), do: v1 + v2

  defp merge_usage_value(v1, v2) when is_map(v1) and is_map(v2) do
    Map.merge(v1, v2, fn _k, v1, v2 -> merge_usage_value(v1, v2) end)
  end

  defp merge_usage_value(_v1, v2), do: v2

  defp maybe_notify_chunk(%State{stream?: true, sink: sink, ref: ref}, chunk) do
    Sink.notify(sink, {:chunk, chunk}, ref)
  end

  defp maybe_notify_chunk(_state, _chunk), do: :ok

  defp maybe_notify_event(%State{stream?: true, sink: sink, ref: ref}, payload) do
    Sink.notify(sink, {:event, payload}, ref)
  end

  defp maybe_notify_event(_state, _payload), do: :ok

  defp ready_tool_calls?(%State{pending_calls: calls}) do
    Enum.any?(calls, &(&1.status == :ready))
  end

  defp execute_tools(%State{} = state) do
    {ready, pending} = Enum.split_with(state.pending_calls, &(&1.status == :ready))

    # Detect infinite tool call loops before executing
    case detect_tool_loop(state, ready) do
      {:loop_detected, call_signature} ->
        raise RuntimeError, "Tool call loop detected: #{inspect(call_signature)}"

      :no_loop ->
        # No loop detected, proceed normally
        {payloads, {messages, tool_context, tool_outputs, call_history}} =
          Enum.map_reduce(
            ready,
            {state.messages, state.tool_context, [], state.tool_call_history},
            fn call, {msgs, ctx, outputs, history} ->
              state_for_call = %{state | tool_context: ctx}
              msgs_with_call = maybe_append_assistant_tool_call(state_for_call, msgs, call)
              {payload, new_msgs, new_ctx} = invoke_tool(state_for_call, call, msgs_with_call)
              # Store tool output info for potential retry (include args for role switching)
              output_info = %{
                call_id: call.id,
                name: call.name,
                args: call.args,
                output: payload.output
              }

              # Track this call in history
              call_signature = {call.name, call.args}
              {payload, {new_msgs, new_ctx, [output_info | outputs], [call_signature | history]}}
            end
          )

        payloads = Enum.reverse(payloads)
        tool_outputs = Enum.reverse(tool_outputs)

        updated_state =
          case state.endpoint do
            # For Responses API, only update tool_payloads, NOT messages
            # Messages are only updated for Chat API where function messages are needed
            :responses -> %{state | tool_payloads: payloads}
            :chat -> %{state | messages: messages}
          end

        %{
          updated_state
          | pending_calls: pending,
            status: :in_progress,
            final_meta: append_tool_meta(state.final_meta, ready),
            tool_context: tool_context,
            last_tool_outputs: tool_outputs,
            tool_call_history: call_history
        }
    end
  end

  defp invoke_tool(state, call, messages) do
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

    new_messages =
      case state.endpoint do
        :chat -> messages ++ [create_tool_output_message(state, call, output)]
        _ -> messages
      end

    {payload, new_messages, new_context}
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

  @doc false
  # Sanitizes exception messages to remove non-deterministic elements like PIDs,
  # user IDs, timestamps, email addresses, and test-generated names/slugs.
  # This ensures cassette stability when exceptions occur during testing.
  defp sanitize_exception_message(message) when is_binary(message) do
    message
    |> String.replace(~r/#PID<\d+\.\d+\.\d+>/, "#PID<0.0.0>")
    |> String.replace(~r/user-\d+@example\.com/, "user-N@example.com")
    |> String.replace(~r/id: \d+/, "id: N")
    |> String.replace(~r/~N\[[^\]]+\]/, "~N[TIMESTAMP]")
    |> String.replace(~r/#Reference<[^>]+>/, "#Reference<REDACTED>")
    |> String.replace(~r/name: "org\d+"/, "name: \"orgN\"")
    |> String.replace(~r/slug: "org\d+"/, "slug: \"orgN\"")
  end

  defp sanitize_exception_message(message), do: message

  defp parse_args(nil), do: %{}

  defp parse_args(fragment) when is_binary(fragment) do
    case Jason.decode(fragment) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, "invalid tool args: #{inspect(error)}"
    end
  end

  defp build_request(%State{} = state), do: build_request(state, true)

  defp build_request(%State{} = state, stream?) do
    %{
      endpoint: state.endpoint,
      url: build_url(state),
      headers: build_headers(state.api_key),
      body: build_body(state, stream?),
      opts: http_opts(state)
    }
  end

  defp build_body(%State{endpoint: :chat} = state, stream?) do
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

    Map.put(base, :metadata, state.metadata)
  end

  defp build_body(%State{endpoint: :responses} = state, stream?) do
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
      metadata: state.metadata,
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
    |> maybe_put(:instructions, state.instructions)
    |> maybe_put(:previous_response_id, state.response_id || state.previous_response_id)
    |> maybe_put(:reasoning, state.reasoning)
    |> maybe_put(:store, state.store)
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
        |> maybe_put(:name, name)
        |> maybe_put(:description, description)
        |> maybe_put(:parameters, parameters)
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

  defp build_url(%State{endpoint: :chat, base_url: base}) do
    trimmed = String.trim_trailing(base, "/")
    trimmed <> "/chat/completions"
  end

  defp build_url(%State{endpoint: :responses, base_url: base}) do
    trimmed = String.trim_trailing(base, "/")
    trimmed <> "/responses"
  end

  defp http_opts(%State{timeout: timeout, cassette: cassette, cassette_index: index}) do
    opts = [receive_timeout: timeout]
    opts = if cassette, do: Keyword.put(opts, :cassette, cassette), else: opts
    opts = if index, do: Keyword.put(opts, :cassette_index, index), else: opts
    opts
  end

  defp build_headers(nil), do: [{"content-type", "application/json"}]

  defp build_headers(api_key) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"}
    ]
  end

  @builtin_tools ~w(code_interpreter file_search web_search_preview)a
  @builtin_tool_strings Enum.map(@builtin_tools, &Atom.to_string/1)

  defp normalize_tools(list) do
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

  defp build_tool_map(tools) do
    tools
    |> Enum.filter(&match?(%Tool{}, &1))
    |> Map.new(&{&1.name, &1})
  end

  defp normalize_input(input, opts) do
    cond do
      Keyword.has_key?(opts, :messages) -> Message.normalize(opts[:messages], opts)
      is_list(input) -> Message.normalize(input, opts)
      true -> Message.normalize(input, opts)
    end
  end

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(map) when is_map(map), do: map
  defp normalize_metadata(list) when is_list(list), do: Map.new(list)
  defp normalize_metadata(_), do: %{}

  defp normalize_reasoning(nil), do: nil
  defp normalize_reasoning(reasoning) when is_map(reasoning), do: reasoning

  defp normalize_reasoning(reasoning) when is_binary(reasoning) do
    %{effort: String.downcase(reasoning)}
  end

  defp normalize_reasoning(_), do: nil

  defp select_reasoning_endpoint(_endpoint, reasoning) when not is_nil(reasoning), do: :responses
  defp select_reasoning_endpoint(endpoint, _), do: endpoint

  defp resolve_api_key({:system, var}) when is_binary(var), do: System.get_env(var)
  defp resolve_api_key(key) when is_binary(key), do: key
  defp resolve_api_key(_), do: nil

  defp config(key) do
    :aquila |> Application.get_env(:openai, []) |> Keyword.get(key)
  end

  defp final_text(%State{} = state) do
    state.acc_chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp build_response(%State{} = state) do
    chunks_text = final_text(state)

    meta =
      state.final_meta
      |> Map.put(:model, state.model)
      |> Map.put(:endpoint, state.endpoint)
      |> Map.put(:status, state.status)
      |> maybe_put_usage(state.usage)

    {fallback_text, meta} = Map.pop(meta, :_fallback_text)

    {text, meta} = resolve_text(chunks_text, fallback_text, meta, state)

    raw = Enum.reverse(state.raw_events)

    Response.new(text, meta, %{events: raw})
  end

  defp maybe_put_usage(map, usage) when usage == %{}, do: map
  defp maybe_put_usage(map, usage), do: Map.put(map, :usage, usage)

  defp normalize_meta(meta) when is_map(meta) do
    Enum.reduce(meta, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {"usage", value}, acc -> Map.put(acc, :usage, value)
      {"tags", value}, acc -> Map.put(acc, :tags, value)
      {"id", value}, acc -> Map.put(acc, :id, value)
      {"response_id", value}, acc -> Map.put(acc, :response_id, value)
      {"previous_response_id", value}, acc -> Map.put(acc, :previous_response_id, value)
      {"metadata", value}, acc -> Map.put(acc, :metadata, value)
      {other_key, value}, acc -> Map.put(acc, other_key, value)
    end)
  end

  defp normalize_meta(meta), do: meta

  defp resolve_text(chunks_text, fallback_text, meta, %State{} = state) do
    cond do
      chunks_text != "" ->
        {chunks_text, meta}

      is_binary(fallback_text) and fallback_text != "" ->
        {fallback_text, meta}

      state.stream? or state.endpoint != :responses ->
        {"", meta}

      true ->
        case fetch_full_response(state) do
          {:ok, text, extra_meta} ->
            merged_meta = merge_meta(meta, extra_meta)
            {text, merged_meta}

          _ ->
            {"", meta}
        end
    end
  end

  defp fetch_full_response(%State{} = state) do
    req = build_request(state, false)

    case state.transport.post(req) do
      {:ok, body} ->
        text = collect_output_text_from_body(body)

        if text == "" do
          {:error, :empty_output}
        else
          extra_meta = build_extra_meta(body)
          {:ok, text, extra_meta}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_output_text_from_body(body) when is_map(body) do
    body
    |> Map.get("output")
    |> case do
      nil -> Map.get(body, :output)
      value -> value
    end
    |> List.wrap()
    |> Enum.flat_map(&extract_output_text_from_body/1)
    |> Enum.join("")
  end

  defp collect_output_text_from_body(_), do: ""

  defp extract_output_text_from_body(%{"type" => "message", "content" => content}) do
    Enum.flat_map(content, &extract_output_text_from_body/1)
  end

  defp extract_output_text_from_body(%{type: "message", content: content}) do
    Enum.flat_map(content, &extract_output_text_from_body/1)
  end

  defp extract_output_text_from_body(%{"type" => "output_text", "text" => text})
       when is_binary(text) do
    [text]
  end

  defp extract_output_text_from_body(%{type: "output_text", text: text}) when is_binary(text) do
    [text]
  end

  defp extract_output_text_from_body(_), do: []

  defp build_extra_meta(body) when is_map(body) do
    usage = Map.get(body, "usage") || Map.get(body, :usage)

    if is_map(usage) do
      %{usage: usage}
    else
      %{}
    end
  end

  defp build_extra_meta(_), do: %{}

  defp merge_meta(meta, extra) when extra == %{}, do: meta

  defp merge_meta(meta, extra) do
    Map.merge(meta, extra, fn
      :usage, value1, value2 when is_map(value1) and is_map(value2) ->
        Map.merge(value1, value2, fn _k, v1, v2 -> v2 || v1 end)

      _key, _value1, value2 ->
        value2
    end)
  end

  defp emit_start(%State{telemetry: %{meta: meta}}) do
    :telemetry.execute([:aquila, :stream, :start], %{system_time: System.system_time()}, meta)
  end

  defp emit_stop(%State{telemetry: %{start_time: start, meta: meta}}, status) do
    duration = System.monotonic_time() - start

    :telemetry.execute(
      [:aquila, :stream, :stop],
      %{duration: duration},
      Map.put(meta, :status, status)
    )
  end

  defp emit_chunk(%State{telemetry: %{meta: meta}}, size) do
    :telemetry.execute([:aquila, :stream, :chunk], %{size: size}, meta)
  end

  defp raise_error(state, reason) do
    Logger.error("Stream failed", reason: inspect(reason), endpoint: state.endpoint)
    Sink.notify(state.sink, {:error, reason}, state.ref)
    raise RuntimeError, "transport error: #{inspect(reason)}"
  end

  defp track_tool_call(calls, %{id: id} = event) do
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

  defp finalize_tool_call(calls, %{id: id} = event) do
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

  defp finalize_all_collecting_calls(calls) do
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

  defp append_tool_meta(meta, ready_calls) do
    tool_info = Enum.map(ready_calls, &Map.take(&1, [:id, :name, :call_id]))
    Map.update(meta, :tool_calls, tool_info, fn existing -> existing ++ tool_info end)
  end

  defp merge_tool_context(current, patch) when patch == %{}, do: current
  defp merge_tool_context(nil, patch), do: patch

  defp merge_tool_context(current, patch) when is_map(current) do
    Map.merge(current, patch, fn _key, _old, new -> new end)
  end

  defp merge_tool_context(current, patch) when is_list(current) do
    if Keyword.keyword?(current) do
      current
      |> Map.new()
      |> Map.merge(patch, fn _key, _old, new -> new end)
    else
      patch
    end
  end

  defp merge_tool_context(_current, patch), do: patch

  defp empty_map_to_nil(%{} = map) when map_size(map) == 0, do: nil
  defp empty_map_to_nil(other), do: other

  defp normalize_tool_output(output) when is_binary(output), do: output

  defp normalize_tool_output(output) when is_map(output) do
    Jason.encode!(output)
  end

  defp normalize_tool_output(other) do
    Jason.encode!(%{result: other})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp maybe_append_assistant_tool_call(%State{endpoint: :chat}, messages, call) do
    append_assistant_tool_call_message(messages, call)
  end

  defp maybe_append_assistant_tool_call(_state, messages, _call), do: messages

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

  # Detects if we're in a tool call loop (same tool being called repeatedly with same args).
  # Returns {:loop_detected, call_signature} if loop found, :no_loop otherwise.
  defp detect_tool_loop(%State{tool_call_history: history}, ready_calls) do
    # Get signatures of calls we're about to make
    new_signatures = Enum.map(ready_calls, fn call -> {call.name, call.args} end)

    # Check if any of these signatures appear 2+ times in recent history (indicating loop)
    Enum.find_value(new_signatures, :no_loop, fn signature ->
      recent_count = Enum.count(Enum.take(history, 8), &(&1 == signature))
      if recent_count >= 1, do: {:loop_detected, signature}, else: nil
    end)
  end

  defp tool_message_format(%State{tool_message_format: format})
       when format in [:text, :tool_result],
       do: format

  defp tool_message_format(_), do: :text

  defp normalize_tool_choice(choice) do
    case choice do
      :auto -> :auto
      "auto" -> :auto
      :required -> :required
      "required" -> :required
      {:function, name} when is_binary(name) -> {:function, name}
      {:function, name} when is_atom(name) -> {:function, Atom.to_string(name)}
      %{} = map -> map
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> :auto
    end
  end

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

  # Determines whether to use the 'tool' role based on detection state.
  # Defaults to the newer tool role unless we've already proven it fails.
  defp should_use_tool_role?(%State{supports_tool_role: nil}), do: true
  # Known to work
  defp should_use_tool_role?(%State{supports_tool_role: true}), do: true
  # Known to fail
  defp should_use_tool_role?(%State{supports_tool_role: false}), do: false
end
