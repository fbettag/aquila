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
  alias Aquila.Engine.Chat
  alias Aquila.Engine.Responses
  alias Aquila.Engine.Shared
  alias Aquila.Message
  alias Aquila.Response
  alias Aquila.Sink
  alias Aquila.Tool

  require Logger

  # Get the endpoint-specific implementation module
  defp get_endpoint_impl(%{endpoint: :chat}), do: Chat
  defp get_endpoint_impl(%{endpoint: :responses}), do: Responses

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
        case detect_tool_message_format_error(state.error, state) do
          {:retry, new_state} ->
            Logger.info("Detected tool message format error, retrying with updated content")
            loop(new_state)

          :no_retry ->
            # Check if this is a role compatibility error that we can retry
            case detect_role_compatibility_error(state.error, state) do
              {:retry, new_state} ->
                Logger.info("Detected role compatibility error, retrying with different format")
                loop(new_state)

              :no_retry ->
                raise_error(state, state.error)
            end
        end

      state.status in [:completed, :succeeded, :done] and
        state.tools != [] and
        state.tool_call_history == [] and
        state.tool_choice == :auto and
          not state.tool_choice_forced? ->
        Logger.info("No tool calls observed; retrying with forced tool choice")
        loop(force_tool_choice(state))

      state.status in [:completed, :succeeded, :done] and
        state.tool_choice_forced? and
        state.tool_call_history == [] and
          state.tools != [] ->
        Logger.warning("Forced tool choice ignored; executing fallback tool invocation")
        execute_fallback_tool_calls(state)

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

        case detect_tool_message_format_error(reason, current_state) do
          {:retry, retry_state} ->
            Logger.info(
              "Detected tool message format error in transport, retrying with updated content"
            )

            do_stream(retry_state)

          :no_retry ->
            # Check if we've already retried too many times
            if current_state.role_retry_count >= 2 do
              Logger.warning("Maximum role retries (2) exceeded, giving up")
              raise_error(current_state, reason)
            else
              # Check if this is a role compatibility error before raising
              case detect_role_compatibility_error(reason, current_state) do
                {:retry, retry_state} ->
                  Logger.info(
                    "Detected role compatibility error in transport (retry #{retry_state.role_retry_count}), retrying with different format"
                  )

                  # Recursively retry with the updated state
                  do_stream(retry_state)

                :no_retry ->
                  raise_error(current_state, reason)
              end
            end
        end
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
    pending = Shared.track_tool_call(state.pending_calls, event)
    %{state | pending_calls: pending, raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :tool_call} = event) do
    # Skip tool_call events with null id - they're malformed
    %{state | raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :tool_call_end} = event) do
    pending = Shared.finalize_tool_call(state.pending_calls, event)
    %{state | pending_calls: pending, raw_events: [event | state.raw_events]}
  end

  defp handle_event(%State{} = state, %{type: :done} = event) do
    status = Map.get(event, :status, :completed)
    meta = event |> Map.get(:meta, %{}) |> normalize_meta()

    # When finish_reason indicates tool calls, ensure all collecting calls are finalized
    state =
      if status == :requires_action do
        %{state | pending_calls: Shared.finalize_all_collecting_calls(state.pending_calls)}
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
        handle_tool_loop_detected(state, ready, pending, call_signature)

      :no_loop ->
        # No loop detected, proceed normally
        endpoint_impl = get_endpoint_impl(state)

        {payloads, {messages, tool_context, tool_outputs, call_history}} =
          Enum.map_reduce(
            ready,
            {state.messages, state.tool_context, [], state.tool_call_history},
            fn call, {msgs, ctx, outputs, history} ->
              state_for_call = %{state | tool_context: ctx}

              msgs_with_call =
                endpoint_impl.maybe_append_assistant_tool_call(state_for_call, msgs, call)

              {payload, new_msgs, new_ctx} =
                Shared.invoke_tool(state_for_call, call, msgs_with_call, endpoint_impl)

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

        # Use endpoint-specific handler for tool outputs
        updated_state =
          endpoint_impl.handle_tool_outputs(
            state,
            payloads,
            messages,
            tool_context,
            tool_outputs,
            call_history
          )

        %{
          updated_state
          | pending_calls: pending,
            status: :in_progress,
            final_meta: Shared.append_tool_meta(state.final_meta, ready)
        }
    end
  end

  defp build_request(%State{} = state), do: build_request(state, true)

  defp build_request(%State{} = state, stream?) do
    endpoint_impl = get_endpoint_impl(state)

    %{
      endpoint: state.endpoint,
      url: endpoint_impl.build_url(state),
      headers: build_headers(state.api_key),
      body: endpoint_impl.build_body(state, stream?),
      opts: http_opts(state)
    }
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

    # Extract _fallback_text BEFORE adding messages to preserve it
    # Try both atom and string keys since cassettes use strings
    {fallback_text, final_meta_without_fallback} =
      case Map.pop(state.final_meta, :_fallback_text) do
        {nil, meta} -> Map.pop(meta, "_fallback_text")
        result -> result
      end

    meta =
      final_meta_without_fallback
      |> Map.put(:model, state.model)
      |> Map.put(:endpoint, state.endpoint)
      |> Map.put(:status, state.status)
      |> maybe_put_usage(state.usage)
      |> Map.put(:messages, Message.to_list(state.messages))
      |> maybe_put(:response_id, state.response_id)

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
    Logger.debug("Stream failed", reason: inspect(reason), endpoint: state.endpoint)
    Sink.notify(state.sink, {:error, reason}, state.ref)
    raise RuntimeError, "transport error: #{inspect(reason)}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp handle_tool_loop_detected(%State{} = state, ready_calls, pending_calls, call_signature) do
    {tool_name, tool_args} = call_signature

    Logger.warning(
      "Tool call loop detected; returning error payload instead of executing tool",
      tool: tool_name,
      args: tool_args
    )

    endpoint_impl = get_endpoint_impl(state)

    {payloads, {messages, tool_context, tool_outputs, call_history}} =
      Enum.map_reduce(
        ready_calls,
        {state.messages, state.tool_context, [], state.tool_call_history},
        fn call, {msgs, ctx, outputs, history} ->
          msgs_with_call = endpoint_impl.maybe_append_assistant_tool_call(state, msgs, call)
          args = Shared.extract_tool_call_args(call)

          Sink.notify(
            state.sink,
            {:event, %{type: :tool_call_start, name: call.name, args: args, id: call.id}},
            state.ref
          )

          output_text = Shared.loop_error_output(call, args)
          normalized_output = Shared.normalize_tool_output(output_text)

          Sink.notify(
            state.sink,
            {:event,
             %{
               type: :tool_call_result,
               name: call.name,
               args: args,
               output: normalized_output,
               id: call.id,
               status: :error,
               reason: :loop_detected
             }},
            state.ref
          )

          # Use endpoint-specific tool output appending
          new_messages =
            endpoint_impl.append_tool_output_message(
              state,
              msgs_with_call,
              call,
              normalized_output
            )

          payload = %{
            id: call.id,
            call_id: call.call_id || call.id,
            name: call.name,
            output: normalized_output
          }

          output_info = %{
            call_id: call.id,
            name: call.name,
            args: args,
            output: normalized_output
          }

          call_signature = {call.name, args}

          {payload, {new_messages, ctx, [output_info | outputs], [call_signature | history]}}
        end
      )

    payloads = Enum.reverse(payloads)
    tool_outputs = Enum.reverse(tool_outputs)

    # Use endpoint-specific handler for tool outputs
    updated_state =
      endpoint_impl.handle_tool_outputs(
        state,
        payloads,
        messages,
        tool_context,
        tool_outputs,
        call_history
      )

    %{
      updated_state
      | pending_calls: pending_calls,
        status: :in_progress,
        final_meta: Shared.append_tool_meta(state.final_meta, ready_calls)
    }
  end

  # Detects if we're in a tool call loop (same tool being called repeatedly with same args).
  # Returns {:loop_detected, call_signature} if loop found, :no_loop otherwise.
  defp detect_tool_loop(%State{tool_call_history: history, tool_context: context}, ready_calls) do
    if loop_detection_disabled?(context) do
      :no_loop
    else
      Shared.do_detect_tool_loop(history, ready_calls)
    end
  end

  defp loop_detection_disabled?(context) when is_map(context) do
    Map.get(context, :disable_loop_detection) ||
      Map.get(context, "disable_loop_detection") ||
      false
  end

  defp loop_detection_disabled?(_), do: false

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

  defp force_tool_choice(%State{} = state) do
    choice = compute_forced_tool_choice(state.tools)

    state
    |> Map.put(:tool_choice, choice)
    |> Map.put(:tool_choice_forced?, true)
    |> Map.put(:role_retry_count, 0)
    |> reset_state_for_retry()
  end

  defp compute_forced_tool_choice(tools) do
    case Enum.find_value(tools, &tool_name/1) do
      nil -> :required
      name -> {:function, name}
    end
  end

  defp tool_name(%Tool{name: name}), do: name
  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(%{type: "function", function: %{"name" => name}}), do: name
  defp tool_name(%{type: "function", function: %{name: name}}), do: name
  defp tool_name(_), do: nil

  defp reset_state_for_retry(state) do
    %{
      state
      | acc_chunks: [],
        raw_events: [],
        pending_calls: [],
        status: :in_progress,
        # Preserve final_meta and usage since they contain cumulative data from previous rounds
        # (e.g. _fallback_text from deep research, usage stats, response_id)
        tool_payloads: [],
        last_tool_outputs: [],
        tool_call_history: []
    }
  end

  defp execute_fallback_tool_calls(%State{} = state) do
    calls = fallback_tool_calls(state)

    if calls == [] do
      state
    else
      fallback_state =
        state
        |> Map.put(:pending_calls, calls)
        |> Map.put(:error, nil)

      executed_state = execute_tools(fallback_state)
      %{executed_state | status: state.status}
    end
  end

  defp fallback_tool_calls(%State{} = state) do
    state
    |> fallback_tools_to_invoke()
    |> Enum.map(&tool_name/1)
    |> Enum.filter(&tool_registered?(state, &1))
    |> Enum.uniq()
    |> Enum.map(&build_synthetic_call/1)
  end

  defp build_synthetic_call(name) do
    id = generate_tool_call_id()

    %{
      id: id,
      call_id: id,
      name: name,
      args: %{},
      args_fragment: "{}",
      status: :ready
    }
  end

  defp fallback_tools_to_invoke(%State{tool_choice: {:function, name}} = state) do
    Enum.filter(state.tools, &match_tool_name?(&1, name))
  end

  defp fallback_tools_to_invoke(%State{} = state), do: state.tools

  defp match_tool_name?(%Tool{name: tool_name}, name) when is_binary(tool_name) do
    tool_name == name
  end

  defp match_tool_name?(%{name: tool_name}, name) when is_binary(tool_name) do
    tool_name == name
  end

  defp match_tool_name?(%{"name" => tool_name}, name) when is_binary(tool_name) do
    tool_name == name
  end

  defp match_tool_name?(%{type: "function", function: %{"name" => tool_name}}, name) do
    tool_name == name
  end

  defp match_tool_name?(%{type: "function", function: %{name: tool_name}}, name) do
    tool_name == name
  end

  defp match_tool_name?(_, _), do: false

  defp generate_tool_call_id do
    "tool_fallback_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp tool_registered?(%State{tool_map: tool_map}, name) when is_binary(name) do
    Map.has_key?(tool_map, name)
  end

  defp tool_registered?(_, _), do: false

  defp detect_tool_message_format_error(error, %State{} = state) do
    message = extract_error_message(error)

    cond do
      requires_structured_tool_result?(message) and state.tool_message_format != :tool_result ->
        endpoint_impl = get_endpoint_impl(state)
        {:retry, endpoint_impl.rebuild_tool_messages_for_retry(state, {:format, :tool_result})}

      rejects_structured_tool_result?(message) and state.tool_message_format == :tool_result ->
        endpoint_impl = get_endpoint_impl(state)
        {:retry, endpoint_impl.rebuild_tool_messages_for_retry(state, {:format, :text})}

      true ->
        :no_retry
    end
  end

  # Detects if an error is due to role compatibility and determines if we should retry.
  # Returns {:retry, new_state} if we should retry with a different role format,
  # or :no_retry if this is a different error or we've already tried both formats.
  # Works for both :chat and :responses endpoints.
  defp detect_role_compatibility_error(error, %State{} = state) do
    error_message = extract_error_message(error)

    cond do
      # Error indicates 'tool' role is not supported and we haven't tried function role yet
      Shared.role_not_supported?(error_message, "tool") and state.supports_tool_role != false ->
        Logger.debug("Model does not support 'tool' role, switching to 'function' role")
        endpoint_impl = get_endpoint_impl(state)
        new_state = endpoint_impl.rebuild_tool_messages_for_retry(state, {:role, false})
        {:retry, new_state}

      # Error indicates 'function' role is not supported and we haven't tried tool role yet
      Shared.role_not_supported?(error_message, "function") and state.supports_tool_role != true ->
        Logger.debug("Model does not support 'function' role, switching to 'tool' role")
        endpoint_impl = get_endpoint_impl(state)
        new_state = endpoint_impl.rebuild_tool_messages_for_retry(state, {:role, true})
        {:retry, new_state}

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
end
