defmodule Aquila.Transport.OpenAI do
  @moduledoc """
  HTTP transport that talks to OpenAI-compatible APIs using `Req` and
  normalises streaming events into simple maps consumed by `Aquila.Engine`.

  The implementation mirrors the Responses API streaming format as closely
  as possible while still shielding callers from protocol quirks. It also
  works with OpenAI-compatible Chat Completions servers by projecting
  tool-call deltas into the same event vocabulary.
  """

  alias Aquila.Transport.OpenAI.Chat
  alias Aquila.Transport.OpenAI.Responses

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
        events = Responses.normalize(payload, state.callback)
        finalize_state(state, events)

      {:error, error} ->
        state.callback.(%{type: :error, error: error})
        state
    end
  end

  defp decode_event(%{endpoint: :chat} = state, data) do
    case Jason.decode(data) do
      {:ok, payload} ->
        {new_state, events} = Chat.normalize(state, payload, state.callback)
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
end
