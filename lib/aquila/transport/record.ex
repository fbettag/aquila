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

  alias Aquila.Transport.{Cassette, Replay}
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

  defp replay_http(method, req, cassette, index) do
    verify_prompt!(req, cassette, index, method)

    cassette
    |> Cassette.post_path(index)
    |> File.read!()
    |> Jason.decode()
  end

  defp record_stream(req, cassette, request_id, callback) do
    clean_req = strip_recorder_opts(req)
    persist_meta(cassette, request_id, clean_req)

    Cassette.ensure_dir(Cassette.sse_path(cassette))
    {:ok, io} = File.open(Cassette.sse_path(cassette), [:append, :utf8])

    writer = fn event ->
      serialized = serialize_event(event, request_id)
      IO.write(io, StableJason.encode!(serialized, sorter: :asc) <> "\n")
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
    # Normalize body before comparing to recorded metadata
    normalized_body = normalize_body(body)

    case Cassette.read_meta(cassette, index) do
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
    old_body = Map.get(meta, "body")
    diff = generate_body_diff(old_body, body)

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

  defp generate_body_diff(old_body, new_body) do
    old_json = Jason.encode!(old_body, pretty: true)
    new_json = Jason.encode!(new_body, pretty: true)

    old_lines = String.split(old_json, "\n")
    new_lines = String.split(new_json, "\n")

    # Use Myers diff algorithm via List.myers_difference
    diff = List.myers_difference(old_lines, new_lines)

    diff
    |> Enum.flat_map(fn
      {:eq, lines} ->
        # Show up to 2 lines of context around changes
        Enum.map(lines, &"  #{&1}")

      {:del, lines} ->
        Enum.map(lines, &"- #{&1}")

      {:ins, lines} ->
        Enum.map(lines, &"+ #{&1}")
    end)
    # Limit to 100 lines to avoid overwhelming output
    |> Enum.take(100)
    |> Enum.join("\n")
  end

  defp cassette_available?(cassette, index, type) do
    case type do
      {:http, _method} ->
        Cassette.exists?(cassette, index, :meta) and Cassette.exists?(cassette, index, :post)

      :sse ->
        Cassette.exists?(cassette, index, :meta) and Cassette.exists?(cassette, index, :sse)
    end
  end

  defp persist_meta(cassette, index, req, method \\ :post) do
    meta = %{
      endpoint: req.endpoint,
      url: req.url,
      model: extract_model(Map.get(req, :body)),
      body: normalize_body(Map.get(req, :body)),
      headers: normalize_headers(req.headers),
      method: Atom.to_string(method)
    }

    Cassette.write_meta(cassette, index, meta)
  end

  # Normalize body by encoding with StableJason and decoding back to ensure
  # keys are in alphabetical order. This makes cassettes independent of how
  # the upstream API sends JSON.
  defp normalize_body(nil), do: nil

  defp normalize_body(body) when is_map(body) do
    body
    |> StableJason.encode!(sorter: :asc)
    |> Jason.decode!()
  end

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        normalize_body(decoded)

      _ ->
        body
    end
  end

  defp normalize_body(body), do: body

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
        canonical_body(recorded_body) == canonical_body(normalized_body)

      :error ->
        true
    end
  end

  defp canonical_body(nil), do: Cassette.canonical_term(:no_body)
  defp canonical_body(body), do: Cassette.canonical_term(body)

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
end
