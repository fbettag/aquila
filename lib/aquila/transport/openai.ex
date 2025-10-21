defmodule Aquila.Transport.OpenAI do
  @moduledoc """
  HTTP transport that talks to OpenAI-compatible APIs using `Req` and
  normalises streaming events into simple maps consumed by `Aquila.Engine`.

  The implementation mirrors the Responses API streaming format as closely
  as possible while still shielding callers from protocol quirks. It also
  works with OpenAI-compatible Chat Completions servers by projecting
  tool-call deltas into the same event vocabulary.
  """

  @behaviour Aquila.Transport

  @doc """
  Issues a JSON POST request using `Req` and returns the decoded body.

  Returns `{:ok, map}` for 2xx responses and `{:error, reason}` for HTTP or
  transport failures. The `:opts` map can include `:receive_timeout` or any
  other Req-compatible options merged into the request.
  """
  @impl true
  def post(%{url: url, headers: headers, body: body, opts: opts}) do
    request =
      Req.new()
      |> Req.merge(method: :post, url: url, headers: headers, json: body)
      |> apply_req_opts(opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @impl true
  def get(%{url: url, headers: headers, opts: opts} = req) do
    request =
      Req.new()
      |> Req.merge(method: :get, url: url, headers: headers)
      |> maybe_put_query(req)
      |> apply_req_opts(opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @impl true
  def delete(%{url: url, headers: headers, opts: opts} = req) do
    request =
      Req.new()
      |> Req.merge(method: :delete, url: url, headers: headers)
      |> maybe_put_body(req)
      |> apply_req_opts(opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, {:http_error, status, response}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  @doc """
  Starts a streaming request, normalising SSE chunks into engine events.

  The callback receives maps with keys such as `:delta`, `:tool_call`, and
  `:done`. A final `:done` event is emitted automatically when the server
  closes the stream without signalling completion explicitly.
  """
  @state_key :aquila_stream_state

  @impl true
  def stream(%{url: url, headers: headers, body: body, opts: opts, endpoint: endpoint}, callback)
      when is_function(callback, 1) do
    ref = make_ref()

    request =
      Req.new()
      |> Req.merge(method: :post, url: url, headers: headers, json: body)
      |> apply_req_opts(opts)
      |> Req.merge(into: stream_fun(endpoint, callback, ref))

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        state = fetch_state(response, endpoint, callback, ref)

        unless state.done? do
          callback.(%{type: :done, status: :completed})
        end

        {:ok, ref}

      {:ok, %Req.Response{status: status, body: body} = response} ->
        state = fetch_state(response, endpoint, callback, ref)
        {:error, {:http_error, status, error_body(state, body)}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp apply_req_opts(request, nil), do: request

  defp apply_req_opts(request, opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000)

    req_opts =
      opts
      |> Keyword.drop([:cassette, :cassette_index])
      |> Keyword.put(:receive_timeout, receive_timeout)

    Req.merge(request, req_opts)
  end

  defp maybe_put_query(request, %{body: body}) when is_map(body) and map_size(body) > 0 do
    Req.merge(request, params: body)
  end

  defp maybe_put_query(request, _), do: request

  defp maybe_put_body(request, %{body: body}) when is_map(body) and map_size(body) > 0 do
    Req.merge(request, json: body)
  end

  defp maybe_put_body(request, _), do: request

  defp stream_fun(endpoint, callback, ref) do
    fn
      {:data, chunk}, {request, response} ->
        state = fetch_state(response, endpoint, callback, ref)
        new_state = handle_chunk(state, to_binary(chunk))
        {:cont, {request, put_state(response, new_state)}}

      chunk, {request, response} when is_binary(chunk) or is_list(chunk) ->
        state = fetch_state(response, endpoint, callback, ref)
        new_state = handle_chunk(state, to_binary(chunk))
        {:cont, {request, put_state(response, new_state)}}

      {:done, _}, acc ->
        {:cont, acc}

      _chunk, acc ->
        {:cont, acc}
    end
  end

  defp init_state(endpoint, callback, ref) do
    %{
      buffer: "",
      endpoint: endpoint,
      callback: callback,
      done?: false,
      ref: ref,
      status: nil,
      raw_body: "",
      tool_calls: %{}
    }
  end

  defp fetch_state(%Req.Response{status: status, private: private}, endpoint, callback, ref) do
    private
    |> Map.get(@state_key, init_state(endpoint, callback, ref))
    |> assign_status(status)
  end

  defp put_state(%Req.Response{} = response, state) do
    put_in(response.private[@state_key], state)
  end

  defp assign_status(%{status: nil} = state, status), do: %{state | status: status}
  defp assign_status(state, _status), do: state

  defp handle_chunk(%{buffer: buffer} = state, chunk) do
    data = buffer <> chunk
    {events, rest} = split_events(data)
    state = %{state | buffer: rest}

    Enum.reduce(events, state, fn event, acc ->
      process_event(acc, event)
    end)
  end

  defp split_events(data) do
    normalized = String.replace(data, "\r\n", "\n")
    parts = String.split(normalized, "\n\n", trim: false)
    rest = List.last(parts) || ""
    events = parts |> Enum.drop(-1) |> Enum.reject(&(&1 == ""))
    {events, rest}
  end

  defp process_event(state, event) when event in ["", nil], do: state

  defp process_event(%{callback: callback} = state, event) do
    data =
      event
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(&1, "data:"))
      |> Enum.map(&String.trim_leading/1)
      |> Enum.join("\n")

    trimmed = String.trim(event)

    cond do
      data == "" and trimmed == "" ->
        state

      data == "" and String.starts_with?(trimmed, ":") ->
        state

      data == "" ->
        accumulate_raw(state, trimmed)

      data == "[DONE]" ->
        callback.(%{type: :done, status: :completed})
        %{state | done?: true}

      true ->
        decode_event(state, data)
    end
  end

  defp accumulate_raw(%{raw_body: raw} = state, fragment) do
    new_raw = raw <> fragment
    %{state | raw_body: new_raw}
  end

  defp error_body(%{raw_body: raw}, _body) when is_binary(raw) and raw != "" do
    raw
  end

  defp error_body(%{buffer: buffer}, _body) when is_binary(buffer) and buffer != "" do
    buffer
  end

  defp error_body(_state, body), do: body

  defp to_binary(chunk) when is_binary(chunk), do: chunk
  defp to_binary(chunk) when is_list(chunk), do: IO.iodata_to_binary(chunk)

  defp decode_event(%{endpoint: :responses} = state, data) do
    case Jason.decode(data) do
      {:ok, payload} ->
        events = normalize_responses(payload)
        Enum.each(events, &state.callback.(&1))
        finalize_state(state, events)

      {:error, error} ->
        state.callback.(%{type: :error, error: error})
        state
    end
  end

  defp decode_event(%{endpoint: :chat} = state, data) do
    case Jason.decode(data) do
      {:ok, payload} ->
        {new_state, events} = normalize_chat(state, payload)
        Enum.each(events, &state.callback.(&1))
        finalize_state(new_state, events)

      {:error, error} ->
        state.callback.(%{type: :error, error: error})
        state
    end
  end

  defp finalize_state(state, events) do
    if Enum.any?(events, &match?(%{type: :done}, &1)) do
      %{state | done?: true}
    else
      state
    end
  end

  # Responses API normalisation ---------------------------------------------

  defp normalize_responses(%{"type" => "response.created", "response" => %{"id" => id}}) do
    [%{type: :response_ref, id: id}]
  end

  defp normalize_responses(%{"type" => "response.output_text.delta", "delta" => delta}) do
    [%{type: :delta, content: delta}]
  end

  defp normalize_responses(%{"type" => "response.output_text.done"}), do: []

  defp normalize_responses(%{"type" => "response.completed", "response" => response}) do
    meta =
      response
      |> Map.take(["id", "status", "usage", "metadata"])
      |> atomise_keys()

    output_events =
      response
      |> Map.get("output", [])
      |> Enum.flat_map(&normalize_response_output/1)

    fallback_text = collect_output_text(response)

    meta =
      if fallback_text == "" do
        meta
      else
        Map.put(meta, :_fallback_text, fallback_text)
      end

    output_events ++ [%{type: :done, status: :completed, meta: meta}]
  end

  defp normalize_responses(%{"type" => "response.requires_action"} = payload) do
    [%{type: :done, status: :requires_action, meta: Map.delete(payload, "type")}]
  end

  defp normalize_responses(%{"type" => "response.output_item.added", "item" => item} = payload)
       when is_map(item) do
    case Map.get(item, "type") do
      "function_call" ->
        [
          %{
            type: :tool_call,
            id: item["call_id"],
            name: item["name"],
            args_fragment: "",
            call_id: item["call_id"]
          },
          %{type: :event, payload: deep_research_payload(payload)}
        ]

      _ ->
        [%{type: :event, payload: deep_research_payload(payload)}]
    end
  end

  defp normalize_responses(%{"type" => "response.output_item.done", "item" => item} = payload)
       when is_map(item) do
    case Map.get(item, "type") do
      "function_call" ->
        args = decode_json_map(item["arguments"] || "{}")

        [
          %{
            type: :tool_call_end,
            id: item["call_id"],
            name: item["name"],
            args: args,
            call_id: item["call_id"]
          },
          %{type: :event, payload: deep_research_payload(payload)}
        ]

      _ ->
        [%{type: :event, payload: deep_research_payload(payload)}]
    end
  end

  defp normalize_responses(%{"type" => "response.in_progress"} = payload) do
    [%{type: :event, payload: deep_research_payload(payload)}]
  end

  defp normalize_responses(%{"type" => "response.error", "error" => error}) do
    [%{type: :error, error: error}]
  end

  defp normalize_responses(%{"type" => "response.function_call_arguments.delta"} = payload) do
    [
      %{
        type: :tool_call,
        id: payload["call_id"],
        name: get_in(payload, ["function_call", "name"]),
        args_fragment: payload["delta"],
        call_id: payload["call_id"]
      }
    ]
  end

  defp normalize_responses(%{"type" => "response.function_call_arguments.done"} = payload) do
    [
      %{
        type: :tool_call_end,
        id: payload["call_id"],
        name: get_in(payload, ["function_call", "name"]),
        args: decode_json_map(payload["arguments"]),
        call_id: payload["call_id"]
      }
    ]
  end

  defp normalize_responses(%{"type" => "response.usage.delta", "usage" => usage}) do
    [%{type: :usage, usage: usage}]
  end

  defp normalize_responses(%{"type" => "response.output_text.chunk", "text" => text}) do
    [%{type: :delta, content: text}]
  end

  defp normalize_responses(%{"type" => type} = payload) when is_binary(type) do
    cond do
      deep_research_event_type?(type) ->
        [%{type: :event, payload: deep_research_payload(payload)}]

      builtin_tool_type?(type) ->
        [builtin_tool_event(payload)]

      true ->
        []
    end
  end

  defp normalize_responses(_payload), do: []

  defp normalize_response_output(%{"type" => "message", "content" => content}) do
    Enum.flat_map(content, &normalize_response_message_content/1)
  end

  defp normalize_response_output(%{"type" => "output_text", "text" => text}) do
    [%{type: :delta, content: text}]
  end

  defp normalize_response_output(_other), do: []

  defp normalize_response_message_content(%{"type" => "output_text", "text" => text}) do
    [%{type: :delta, content: text}]
  end

  defp normalize_response_message_content(%{"type" => "tool_call_delta"} = payload) do
    if function_tool_call?(payload["tool_call"]) do
      [
        %{
          type: :tool_call,
          id: payload["call_id"],
          name: get_in(payload, ["tool_call", "function", "name"]),
          args_fragment: get_in(payload, ["tool_call", "function", "arguments"]),
          call_id: payload["call_id"]
        }
      ]
    else
      [builtin_tool_event(payload, "delta")]
    end
  end

  defp normalize_response_message_content(%{"type" => "tool_call"} = payload) do
    if function_tool_call?(payload["tool_call"]) do
      args = get_in(payload, ["tool_call", "function", "arguments"])

      [
        %{
          type: :tool_call_end,
          id: payload["call_id"],
          name: get_in(payload, ["tool_call", "function", "name"]),
          args: decode_json_map(args),
          call_id: payload["call_id"]
        }
      ]
    else
      [builtin_tool_event(payload, "complete")]
    end
  end

  defp normalize_response_message_content(_other), do: []

  defp collect_output_text(response) do
    response
    |> Map.get("output", [])
    |> Enum.flat_map(&extract_output_text/1)
    |> Enum.join("")
  end

  defp extract_output_text(%{"type" => "message", "content" => content}) do
    content
    |> Enum.flat_map(&extract_output_text/1)
  end

  defp extract_output_text(%{"type" => "output_text", "text" => text}) when is_binary(text) do
    [text]
  end

  defp extract_output_text(_other), do: []

  # Chat completions ---------------------------------------------------------

  defp normalize_chat(state, %{"choices" => choices} = payload) do
    meta = Map.take(payload, ["id", "model"]) |> atomise_keys()

    {new_state, all_events} =
      Enum.reduce(choices, {state, []}, fn choice, {acc_state, acc_events} ->
        delta = choice["delta"] || %{}
        finish = choice["finish_reason"]

        # Accumulate tool call fragments in state
        {updated_state, tool_events} = normalize_chat_tool_calls(acc_state, delta, finish)

        choice_events =
          []
          |> maybe_add_delta(delta["content"])
          |> Kernel.++(tool_events)

        {updated_state, acc_events ++ choice_events}
      end)

    # Add finish and usage events after processing all choices
    final_events =
      all_events
      |> Kernel.++(
        synthesize_tool_call_ends(new_state, Enum.at(choices, 0)["finish_reason"], meta)
      )
      |> Kernel.++(finish_events(Enum.at(choices, 0)["finish_reason"], meta))
      |> Kernel.++(usage_events(payload))

    # Only clear tool_calls after we've synthesized the tool_call_end events
    # (i.e., when finish_reason is "tool_calls")
    finish_reason = Enum.at(choices, 0)["finish_reason"]

    final_state =
      if finish_reason == "tool_calls", do: %{new_state | tool_calls: %{}}, else: new_state

    {final_state, final_events}
  end

  defp maybe_add_delta(events, nil), do: events
  defp maybe_add_delta(events, content), do: events ++ [%{type: :delta, content: content}]

  defp normalize_chat_tool_calls(state, %{"tool_calls" => calls}, _finish_reason)
       when is_list(calls) do
    {new_state, events} =
      Enum.reduce(calls, {state, []}, fn call, {acc_state, acc_events} ->
        function = call["function"] || %{}
        id = call["id"]
        # OpenAI uses index to track tool calls in streaming
        index = call["index"]
        name = function["name"]
        args_fragment = function["arguments"]

        cond do
          # Start tracking new tool call (has id and name)
          not is_nil(id) and not is_nil(name) ->
            # Include the initial args_fragment if present and non-empty (parallel tool call mode sends complete args in first chunk)
            initial_fragments =
              if is_binary(args_fragment) and args_fragment != "", do: [args_fragment], else: []

            # Store by index for subsequent fragment accumulation
            updated_calls =
              Map.put(acc_state.tool_calls, index, %{
                id: id,
                name: name,
                fragments: initial_fragments,
                index: index
              })

            event = %{
              type: :tool_call,
              id: id,
              name: name,
              args_fragment: args_fragment,
              call_id: id
            }

            {%{acc_state | tool_calls: updated_calls}, acc_events ++ [event]}

          # Accumulate fragment for existing tool call (identified by index)
          not is_nil(args_fragment) and not is_nil(index) ->
            case Map.get(acc_state.tool_calls, index) do
              nil ->
                # Tool call not initialized yet - skip this fragment
                {acc_state, acc_events}

              existing_call ->
                updated_calls =
                  Map.put(acc_state.tool_calls, index, %{
                    existing_call
                    | fragments: existing_call.fragments ++ [args_fragment]
                  })

                event = %{
                  type: :tool_call,
                  id: nil,
                  name: nil,
                  args_fragment: args_fragment,
                  call_id: existing_call.id
                }

                {%{acc_state | tool_calls: updated_calls}, acc_events ++ [event]}
            end

          true ->
            {acc_state, acc_events}
        end
      end)

    {new_state, events}
  end

  defp normalize_chat_tool_calls(state, _, _), do: {state, []}

  defp synthesize_tool_call_ends(state, "tool_calls", _meta) do
    # When finish_reason is "tool_calls", synthesize tool_call_end events from accumulated fragments
    Enum.map(state.tool_calls, fn {_id, call} ->
      args_json = Enum.join(call.fragments, "")

      args =
        cond do
          args_json == "" ->
            %{}

          true ->
            case Jason.decode(args_json) do
              {:ok, decoded} ->
                decoded

              {:error, error} ->
                require Logger
                Logger.warning("Failed to decode tool args JSON: #{inspect(error)}")
                Logger.debug("Args JSON was: #{inspect(args_json)}")
                %{}
            end
        end

      %{
        type: :tool_call_end,
        id: call.id,
        name: call.name,
        args: args,
        call_id: call.id
      }
    end)
  end

  defp synthesize_tool_call_ends(_state, _finish_reason, _meta), do: []

  defp finish_events("stop", meta), do: [%{type: :done, status: :completed, meta: meta}]

  defp finish_events("tool_calls", meta) do
    [%{type: :done, status: :requires_action, meta: Map.put(meta, :reason, "tool_calls")}]
  end

  defp finish_events(nil, _), do: []
  defp finish_events(other, _), do: [%{type: :event, payload: %{finish_reason: other}}]

  defp usage_events(%{"usage" => usage}), do: [%{type: :usage, usage: usage}]
  defp usage_events(_), do: []

  defp builtin_tool_event(payload, stage_override \\ nil) do
    stage = stage_override || builtin_stage_from_type(Map.get(payload, "type"))
    tool = Map.get(payload, "tool_call")

    %{
      type: :event,
      payload:
        %{
          source: :builtin_tool,
          stage: stage,
          call_id: call_id_from(payload),
          tool: tool,
          delta: Map.get(payload, "delta"),
          output: Map.get(payload, "output"),
          status: Map.get(payload, "status"),
          raw: payload
        }
        |> compact()
    }
  end

  defp function_tool_call?(%{"function" => _}), do: true
  defp function_tool_call?(%{"type" => "function"}), do: true
  defp function_tool_call?(_), do: false

  defp call_id_from(payload) do
    payload["call_id"] || payload["tool_call_id"] || get_in(payload, ["tool_call", "id"])
  end

  defp builtin_stage_from_type(type) when is_binary(type) do
    type
    |> String.split(".")
    |> List.last()
  end

  defp builtin_stage_from_type(_), do: nil

  defp builtin_tool_type?(type) do
    String.starts_with?(type, "response.tool_call") or
      String.starts_with?(type, "response.builtin_tool")
  end

  @deep_research_prefixes [
    "response.output_item.",
    "response.web_search_call.",
    "response.reasoning.",
    "response.summary.",
    "response.research_step.",
    "response.research_message."
  ]

  defp deep_research_event_type?(type) when is_binary(type) do
    Enum.any?(@deep_research_prefixes, &String.starts_with?(type, &1))
  end

  defp deep_research_event_type?(_), do: false

  defp deep_research_payload(%{"type" => type} = payload) do
    %{
      source: :deep_research,
      type: type,
      event: deep_research_event_name(type),
      data: payload |> Map.delete("type") |> atomise_deep(),
      raw: payload
    }
  end

  defp deep_research_event_name(type) when is_binary(type) do
    type
    |> String.replace_prefix("response.", "")
    |> String.replace(".", "_")
    |> String.to_atom()
  end

  defp atomise_deep(%{} = map) do
    Enum.into(map, %{}, fn {k, v} -> {atomise_key(k), atomise_deep(v)} end)
  end

  defp atomise_deep(list) when is_list(list), do: Enum.map(list, &atomise_deep/1)
  defp atomise_deep(other), do: other

  defp compact(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp decode_json_map(nil), do: nil

  defp decode_json_map(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, map} -> map
      {:error, _} -> %{"raw" => binary}
    end
  end

  defp atomise_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {atomise_key(k), v} end)
  end

  defp atomise_key(k) when is_atom(k), do: k
  defp atomise_key("id"), do: :id
  defp atomise_key("status"), do: :status
  defp atomise_key("usage"), do: :usage
  defp atomise_key("metadata"), do: :metadata
  defp atomise_key("model"), do: :model
  defp atomise_key("reason"), do: :reason
  defp atomise_key("output_index"), do: :output_index
  defp atomise_key("sequence_number"), do: :sequence_number
  defp atomise_key("item"), do: :item
  defp atomise_key("response"), do: :response
  defp atomise_key(k) when is_binary(k), do: k
  defp atomise_key(k), do: k
end
