defmodule Aquila.Transport.Record do
  @moduledoc """
  Auto-recording transport inspired by ExVCR.

  When a cassette is available this transport replays it without issuing
  network calls. When a cassette is missing it transparently calls the
  configured HTTP transport, captures the traffic, and persists it for
  future runs. Cassette metadata stores a canonicalised copy of the request
  payload and mismatches raise with guidance to re-record, guaranteeing that
  prompt drift is detected immediately instead of silently reusing stale
  fixtures.

  ## Prompt Verification

  Each recording stores a canonicalised copy of the request body alongside the
  originating URL, model, and headers. On replay the current body is normalised
  and compared structurally. A mismatch raises with a precise set of files to
  delete, helping developers keep fixtures in sync when instructions or tools
  change.
  """

  @behaviour Aquila.Transport

  alias Aquila.Transport.{Body, Cassette, Replay}
  alias StableJason

  @doc """
  Replays or records non-streaming requests depending on cassette availability.

  When the cassette exists the request body is normalised and compared before
  the stored response is returned. Otherwise the request is proxied to the
  inner transport, persisted, and replayed to the caller.
  """
  @impl true
  def post(req), do: handle_http(:post, req)

  @impl true
  def get(req), do: handle_http(:get, req)

  @impl true
  def delete(req), do: handle_http(:delete, req)

  @doc """
  Replays or records streaming responses, mirroring each event to the caller.

  Missing cassettes trigger a real network call whose events are written to a
  JSONL file while being forwarded to the callback. Subsequent runs verify the
  prompt body and stream the persisted events.
  """
  @impl true
  def stream(%{opts: opts} = req, callback) do
    with {:ok, cassette} <- fetch_cassette(opts) do
      index = Cassette.next_index(cassette, opts)

      case resolve_mode(req, cassette, index, :sse) do
        {:replay, _meta} ->
          replay_stream(req, cassette, index, callback)

        :record ->
          with_cassette_lock(cassette, fn -> record_stream(req, cassette, index, callback) end)
      end
    else
      :no_cassette -> inner_transport().stream(strip_recorder_opts(req), callback)
    end
  end

  defp handle_http(method, req) do
    opts = Map.get(req, :opts, [])

    with {:ok, cassette} <- fetch_cassette(opts) do
      index = Cassette.next_index(cassette, opts)

      case resolve_mode(req, cassette, index, {:http, method}) do
        {:replay, _meta} ->
          replay_http(method, req, cassette, index)

        :record ->
          with_cassette_lock(cassette, fn -> record_http(method, req, cassette, index) end)
      end
    else
      :no_cassette -> call_inner(method, strip_recorder_opts(req))
    end
  end

  defp record_http(method, req, cassette, index) do
    clean_req = strip_recorder_opts(req)

    case call_inner(method, clean_req) do
      {:ok, body} = ok ->
        persist_meta(cassette, index, clean_req, method)
        Cassette.ensure_dir(Cassette.post_path(cassette, index))

        File.write!(
          Cassette.post_path(cassette, index),
          StableJason.encode!(body, sorter: :asc, pretty: true)
        )

        ok

      other ->
        other
    end
  end

  defp replay_http(_method, _req, cassette, index) do
    cassette
    |> Cassette.post_path(index)
    |> File.read!()
    |> Jason.decode()
  end

  defp record_stream(req, cassette, request_id, callback) do
    clean_req = strip_recorder_opts(req)
    persist_meta(cassette, request_id, clean_req)
    Cassette.cache_sse_request(cassette, request_id)

    Cassette.ensure_dir(Cassette.sse_path(cassette))
    {:ok, io} = File.open(Cassette.sse_path(cassette), [:append, :utf8])

    writer = fn event ->
      serialized = serialize_event(event, request_id)
      Cassette.append_sse_event(cassette, request_id, serialized)
      IO.write(io, StableJason.encode!(serialized, sorter: :asc) <> "\n")
      callback.(event)
    end

    try do
      inner_transport().stream(clean_req, writer)
    after
      File.close(io)
      Cassette.refresh_sse_cache(cassette)
    end
  end

  defp replay_stream(req, _cassette, index, callback) do
    req
    |> put_index(index)
    |> skip_verification()
    |> Replay.stream(callback)
  end

  defp verify_prompt!(req, cassette, index, method, meta_override) do
    clean_req = strip_recorder_opts(req)
    body = Map.get(clean_req, :body)
    # Normalize body before comparing to recorded metadata
    normalized_body = Body.normalize(body)

    case resolve_meta(meta_override, cassette, index) do
      {:ok, meta} ->
        cond do
          !method_matches?(meta, method) ->
            path = Cassette.meta_path(cassette)
            raise_method_mismatch(path, meta, method)

          bodies_match?(meta, normalized_body) ->
            :ok

          true ->
            path = Cassette.meta_path(cassette)
            raise_prompt_mismatch(path, meta, normalized_body)
        end

      {:error, {:meta_missing, path, _}} ->
        raise "Cassette meta missing at #{path}. Remove cassette and re-record."

      {:error, reason} ->
        raise "Unable to load cassette meta: #{inspect(reason)}"
    end
  end

  defp raise_prompt_mismatch(path, meta, body) do
    base = Path.rootname(path, ".meta.jsonl")
    files = Enum.join([path, base <> ".sse.jsonl"], " ")

    # Generate git-style diff of the prompt bodies
    # body is already normalized from verify_prompt!
    recorded_body = Map.get(meta, "body")
    diff = Body.diff(recorded_body, body)

    message =
      [
        "Cassette prompt mismatch for request #{meta["request_id"]} in #{path}.",
        "Recorded request body no longer matches the current request.",
        "",
        "Diff:",
        diff,
        "",
        "Remove the cassette (e.g. rm #{files}) and re-record or update it to match."
      ]
      |> Enum.join("\n")

    raise RuntimeError, message
  end

  defp resolve_mode(req, cassette, index, {:http, method}) do
    with {:ok, meta} <- Cassette.read_meta(cassette, index),
         true <- File.exists?(Cassette.post_path(cassette, index)) do
      verify_prompt!(req, cassette, index, method, meta)
      {:replay, meta}
    else
      {:error, _reason} -> :record
      false -> :record
    end
  end

  defp resolve_mode(req, cassette, index, :sse) do
    with {:ok, meta} <- Cassette.read_meta(cassette, index),
         true <- Cassette.exists?(cassette, index, :sse) do
      verify_prompt!(req, cassette, index, :post, meta)
      {:replay, meta}
    else
      {:error, _reason} -> :record
      false -> :record
    end
  end

  defp resolve_meta(%{} = meta, _cassette, _index), do: {:ok, meta}
  defp resolve_meta({:ok, %{} = meta}, _cassette, _index), do: {:ok, meta}
  defp resolve_meta(_meta_override, cassette, index), do: Cassette.read_meta(cassette, index)

  defp persist_meta(cassette, index, req, method \\ :post) do
    meta = %{
      endpoint: req.endpoint,
      url: req.url,
      model: extract_model(Map.get(req, :body)),
      body: Body.normalize(Map.get(req, :body)),
      headers: normalize_headers(req.headers),
      method: Atom.to_string(method)
    }

    Cassette.write_meta(cassette, index, meta)
  end

  defp call_inner(:post, req), do: inner_transport().post(req)
  defp call_inner(:get, req), do: inner_transport().get(req)
  defp call_inner(:delete, req), do: inner_transport().delete(req)

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {key, value} -> [key, mask_header(key, value)]
      [key, value] -> [key, mask_header(key, value)]
      other -> other
    end)
  end

  defp normalize_headers(_), do: []

  defp mask_header(key, value) when is_binary(key) do
    if String.downcase(key) == "authorization" do
      "[redacted]"
    else
      value
    end
  end

  defp mask_header(_key, value), do: value

  defp method_matches?(%{"method" => nil}, method), do: method in [:post, "post"]

  defp method_matches?(%{"method" => recorded}, method) when is_binary(recorded),
    do: recorded == Atom.to_string(method)

  defp method_matches?(%{"method" => recorded}, method) when is_atom(recorded),
    do: Atom.to_string(recorded) == Atom.to_string(method)

  defp method_matches?(_, :post), do: true
  defp method_matches?(_, _method), do: false

  defp bodies_match?(meta, normalized_body) do
    case Map.fetch(meta, "body") do
      {:ok, recorded_body} ->
        Body.equivalent?(recorded_body, normalized_body)

      :error ->
        true
    end
  end

  defp raise_method_mismatch(path, meta, method) do
    recorded = meta["method"] || "post"

    message =
      [
        "Cassette method mismatch for #{path}.",
        "Recorded method: #{recorded}",
        "Current method: #{Atom.to_string(method)}",
        "Remove the cassette files and re-record."
      ]
      |> Enum.join("\n")

    raise RuntimeError, message
  end

  defp extract_model(body) when is_map(body), do: body[:model] || body["model"]
  defp extract_model(_), do: nil

  defp serialize_event(%{type: :event, payload: payload}, request_id),
    do: %{"type" => "event", "payload" => payload, "request_id" => request_id}

  defp serialize_event(%{type: :event} = event, request_id),
    do: %{"type" => "event", "payload" => Map.drop(event, [:type]), "request_id" => request_id}

  defp serialize_event(%{type: :delta, content: content}, request_id),
    do: %{"type" => "delta", "content" => content, "request_id" => request_id}

  defp serialize_event(%{type: :message, content: content}, request_id),
    do: %{"type" => "message", "content" => content, "request_id" => request_id}

  defp serialize_event(%{type: :tool_call} = event, request_id),
    do: %{
      "type" => "tool_call",
      "id" => event[:id],
      "name" => event[:name],
      "args_fragment" => event[:args_fragment],
      "call_id" => event[:call_id],
      "request_id" => request_id
    }

  defp serialize_event(%{type: :tool_call_end} = event, request_id),
    do: %{
      "type" => "tool_call_end",
      "id" => event[:id],
      "name" => event[:name],
      "args" => event[:args],
      "call_id" => event[:call_id],
      "request_id" => request_id
    }

  defp serialize_event(%{type: :response_ref, id: id}, request_id),
    do: %{"type" => "response_ref", "id" => id, "request_id" => request_id}

  defp serialize_event(%{type: :usage, usage: usage}, request_id),
    do: %{"type" => "usage", "usage" => usage, "request_id" => request_id}

  defp serialize_event(%{type: :done} = event, request_id),
    do: %{
      "type" => "done",
      "status" => event[:status],
      "meta" => event[:meta],
      "request_id" => request_id
    }

  defp serialize_event(%{type: :error, error: error}, request_id),
    do: %{"type" => "error", "error" => error, "request_id" => request_id}

  defp serialize_event(other, request_id),
    do: %{"type" => "event", "payload" => other, "request_id" => request_id}

  defp fetch_cassette(opts) do
    case Keyword.get(opts, :cassette) do
      nil -> :no_cassette
      value -> {:ok, value}
    end
  end

  defp inner_transport do
    Application.get_env(:aquila, :recorder, [])
    |> Keyword.get(:transport, Aquila.Transport.OpenAI)
  end

  defp strip_recorder_opts(%{opts: opts} = req) when is_list(opts) do
    %{req | opts: Keyword.delete(opts, :cassette_index) |> Keyword.delete(:cassette)}
  end

  defp strip_recorder_opts(req), do: req

  defp put_index(%{opts: opts} = req, index) when is_list(opts) do
    %{req | opts: Keyword.put(opts, :cassette_index, index)}
  end

  defp put_index(req, index), do: %{req | opts: [cassette_index: index]}

  # Serialize cassette recording to prevent concurrent writers from producing
  # mismatched metadata/SSE files when the same cassette is recorded in
  # multiple processes (e.g. async LiveView tasks during tests).
  defp with_cassette_lock(cassette, fun) when is_function(fun, 0) do
    :global.trans({:aquila_record, cassette}, fun)
  end

  defp skip_verification(%{opts: opts} = req) when is_list(opts) do
    %{req | opts: Keyword.put(opts, :skip_verification, true)}
  end

  defp skip_verification(req), do: Map.put(req, :opts, skip_verification: true)
end
