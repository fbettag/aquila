defmodule Aquila.Transport.Record do
  @moduledoc """
  Auto-recording transport inspired by ExVCR.

  When a cassette is available this transport replays it without issuing
  network calls. When a cassette is missing it transparently calls the
  configured HTTP transport, captures the traffic, and persists it for
  future runs. Cassette metadata includes a canonical hash of the request
  payload and mismatches raise with guidance to re-record, guaranteeing that
  prompt drift is detected immediately instead of silently reusing stale
  fixtures.

  ## Prompt Verification

  Each recording stores a canonical hash of the request body alongside the
  originating URL, model, and headers. On replay the hash is recomputed and
  compared. A mismatch raises with a precise set of files to delete, helping
  developers keep fixtures in sync when instructions or tools change.
  """

  @behaviour Aquila.Transport

  alias Aquila.Transport.{Cassette, Replay}

  @doc """
  Replays or records non-streaming requests depending on cassette availability.

  When the cassette exists the request body hash is validated before the
  stored response is returned. Otherwise the request is proxied to the inner
  transport, persisted, and replayed to the caller.
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
  prompt hash and stream the persisted events.
  """
  @impl true
  def stream(%{opts: opts} = req, callback) do
    with {:ok, cassette} <- fetch_cassette(opts) do
      index = Cassette.next_index(cassette, opts)

      if cassette_available?(cassette, index, :sse) do
        replay_stream(req, cassette, index, callback)
      else
        record_stream(req, cassette, index, callback)
      end
    else
      :no_cassette -> inner_transport().stream(strip_recorder_opts(req), callback)
    end
  end

  defp handle_http(method, req) do
    opts = Map.get(req, :opts, [])

    with {:ok, cassette} <- fetch_cassette(opts) do
      index = Cassette.next_index(cassette, opts)

      if cassette_available?(cassette, index, {:http, method}) do
        replay_http(method, req, cassette, index)
      else
        record_http(method, req, cassette, index)
      end
    else
      :no_cassette -> call_inner(method, strip_recorder_opts(req))
    end
  end

  defp record_http(method, req, cassette, index) do
    clean_req = strip_recorder_opts(req)
    body = Map.get(clean_req, :body)
    body_hash = request_hash(body)

    case call_inner(method, clean_req) do
      {:ok, body} = ok ->
        persist_meta(cassette, index, clean_req, body_hash, method)
        Cassette.ensure_dir(Cassette.post_path(cassette, index))

        File.write!(
          Cassette.post_path(cassette, index),
          Jason.encode_to_iodata!(body, pretty: true)
        )

        ok

      other ->
        other
    end
  end

  defp replay_http(method, req, cassette, index) do
    verify_prompt!(req, cassette, index, method)

    cassette
    |> Cassette.post_path(index)
    |> File.read!()
    |> Jason.decode()
  end

  defp record_stream(req, cassette, index, callback) do
    clean_req = strip_recorder_opts(req)
    body_hash = request_hash(clean_req.body)
    persist_meta(cassette, index, clean_req, body_hash)

    Cassette.ensure_dir(Cassette.sse_path(cassette, index))
    {:ok, io} = File.open(Cassette.sse_path(cassette, index), [:write])

    writer = fn event ->
      IO.write(io, Jason.encode!(serialize_event(event)) <> "\n")
      callback.(event)
    end

    try do
      inner_transport().stream(clean_req, writer)
    after
      File.close(io)
    end
  end

  defp replay_stream(req, cassette, index, callback) do
    verify_prompt!(req, cassette, index, :post)

    req
    |> put_index(index)
    |> Replay.stream(callback)
  end

  defp verify_prompt!(req, cassette, index, method) do
    clean_req = strip_recorder_opts(req)
    body = Map.get(clean_req, :body)

    case Cassette.read_meta(cassette, index) do
      {:ok, meta} ->
        hash = request_hash(body)

        cond do
          !method_matches?(meta, method) ->
            path = Cassette.meta_path(cassette, index)
            raise_method_mismatch(path, meta, method)

          meta["body_hash"] == hash ->
            :ok

          true ->
            path = Cassette.meta_path(cassette, index)
            raise_prompt_mismatch(path, meta, clean_req.body, hash)
        end

      {:error, {:meta_missing, path, _}} ->
        raise "Cassette meta missing at #{path}. Remove cassette and re-record."

      {:error, reason} ->
        raise "Unable to load cassette meta: #{inspect(reason)}"
    end
  end

  defp raise_prompt_mismatch(path, meta, _body, hash) do
    base = Path.rootname(path, ".meta.json")
    files = Enum.join([path, base <> ".sse.jsonl", base <> ".json"], " ")

    message =
      [
        "Cassette prompt mismatch for #{path}.",
        "Old hash: #{meta["body_hash"]}",
        "New hash: #{hash}",
        "Remove the cassette (e.g. rm #{files}) and re-record."
      ]
      |> Enum.join("\n")

    raise RuntimeError, message
  end

  defp cassette_available?(cassette, index, type) do
    case type do
      {:http, _method} ->
        Cassette.exists?(cassette, index, :meta) and Cassette.exists?(cassette, index, :post)

      :sse ->
        Cassette.exists?(cassette, index, :meta) and Cassette.exists?(cassette, index, :sse)
    end
  end

  defp persist_meta(cassette, index, req, body_hash, method \\ :post) do
    meta = %{
      endpoint: req.endpoint,
      url: req.url,
      model: extract_model(Map.get(req, :body)),
      body_hash: body_hash,
      body: Map.get(req, :body),
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

  defp request_hash(nil), do: Cassette.canonical_hash(:no_body)
  defp request_hash(body), do: Cassette.canonical_hash(body)

  defp extract_model(body) when is_map(body), do: body[:model] || body["model"]
  defp extract_model(_), do: nil

  defp serialize_event(%{type: :event, payload: payload}),
    do: %{"type" => "event", "payload" => payload}

  defp serialize_event(%{type: :event} = event),
    do: %{"type" => "event", "payload" => Map.drop(event, [:type])}

  defp serialize_event(%{type: :delta, content: content}),
    do: %{"type" => "delta", "content" => content}

  defp serialize_event(%{type: :message, content: content}),
    do: %{"type" => "message", "content" => content}

  defp serialize_event(%{type: :tool_call} = event),
    do: %{
      "type" => "tool_call",
      "id" => event[:id],
      "name" => event[:name],
      "args_fragment" => event[:args_fragment],
      "call_id" => event[:call_id]
    }

  defp serialize_event(%{type: :tool_call_end} = event),
    do: %{
      "type" => "tool_call_end",
      "id" => event[:id],
      "name" => event[:name],
      "args" => event[:args],
      "call_id" => event[:call_id]
    }

  defp serialize_event(%{type: :response_ref, id: id}),
    do: %{"type" => "response_ref", "id" => id}

  defp serialize_event(%{type: :usage, usage: usage}), do: %{"type" => "usage", "usage" => usage}

  defp serialize_event(%{type: :done} = event),
    do: %{"type" => "done", "status" => event[:status], "meta" => event[:meta]}

  defp serialize_event(%{type: :error, error: error}), do: %{"type" => "error", "error" => error}
  defp serialize_event(other), do: %{"type" => "event", "payload" => other}

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
end
