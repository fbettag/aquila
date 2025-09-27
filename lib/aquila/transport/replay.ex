defmodule Aquila.Transport.Replay do
  @moduledoc """
  Deterministic, verification-first transport that replays prerecorded
  cassette events. Used heavily in tests to avoid external HTTP calls and to
  ensure tests fail loudly when prompts change without the cassette being
  refreshed.
  """

  @behaviour Aquila.Transport

  alias Aquila.Transport.Cassette

  @doc """
  Replays a previously recorded non-streaming response and validates the prompt hash.

  Returns an error if the cassette is missing or if the stored metadata does
  not match the current request body.
  """
  @impl true
  def post(req), do: handle_http(:post, req)

  @impl true
  def get(req), do: handle_http(:get, req)

  @impl true
  def delete(req), do: handle_http(:delete, req)

  @doc """
  Streams recorded SSE events to the provided callback.

  Each JSONL line is decoded into the normalised event map expected by the
  engine. Prompt mismatches raise with guidance on re-recording the cassette.
  """
  @impl true
  def stream(%{opts: opts} = req, callback) when is_function(callback, 1) do
    with {:ok, cassette} <- fetch_cassette(opts) do
      index = Cassette.next_index(cassette, opts)
      verify_prompt!(req, cassette, index, :post)

      cassette
      |> Cassette.sse_path(index)
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.each(fn line ->
        case Jason.decode!(line) do
          %{"type" => "meta"} -> :ok
          event -> event |> to_event() |> callback.()
        end
      end)

      {:ok, make_ref()}
    else
      :no_cassette -> {:error, :missing_cassette}
    end
  end

  defp handle_http(method, req) do
    opts = Map.get(req, :opts, [])

    with {:ok, cassette} <- fetch_cassette(opts) do
      index = Cassette.next_index(cassette, opts)
      verify_prompt!(req, cassette, index, method)

      cassette
      |> Cassette.post_path(index)
      |> File.read!()
      |> Jason.decode()
    else
      :no_cassette -> {:error, :missing_cassette}
    end
  end

  defp verify_prompt!(%{body: body}, cassette, index, method) do
    case Cassette.read_meta(cassette, index) do
      {:ok, meta} ->
        hash = request_hash(body)

        cond do
          !method_matches?(meta, method) ->
            path = Cassette.meta_path(cassette, index)
            raise_method_mismatch(path, method, meta)

          meta["body_hash"] == hash ->
            :ok

          true ->
            path = Cassette.meta_path(cassette, index)

            message =
              [
                "Cassette prompt mismatch for #{path}.",
                "Recorded hash: #{meta["body_hash"]}",
                "Current hash: #{hash}",
                "Remove the cassette files and re-record."
              ]
              |> Enum.join("\n")

            raise RuntimeError, message
        end

      {:error, {:meta_missing, path, _}} ->
        raise "Cassette metadata missing at #{path}."

      {:error, reason} ->
        raise "Unable to read cassette metadata: #{inspect(reason)}"
    end
  end

  defp request_hash(nil), do: Cassette.canonical_hash(:no_body)
  defp request_hash(body), do: Cassette.canonical_hash(body)

  defp method_matches?(%{"method" => nil}, method), do: method == :post

  defp method_matches?(%{"method" => recorded}, method) when is_binary(recorded) do
    recorded == Atom.to_string(method)
  end

  defp method_matches?(%{"method" => recorded}, method) when is_atom(recorded) do
    Atom.to_string(recorded) == Atom.to_string(method)
  end

  defp method_matches?(_, :post), do: true
  defp method_matches?(_, _method), do: false

  defp raise_method_mismatch(path, method, meta) do
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

  defp fetch_cassette(opts) do
    case Keyword.get(opts, :cassette) do
      nil -> :no_cassette
      value -> {:ok, value}
    end
  end

  defp to_event(%{"type" => "delta", "content" => content}) do
    %{type: :delta, content: content}
  end

  defp to_event(%{"type" => "message", "content" => content}) do
    %{type: :message, content: content}
  end

  defp to_event(%{"type" => "tool_call"} = map) do
    %{
      type: :tool_call,
      id: map["id"] || map["tool_call_id"],
      name: map["name"],
      args_fragment: Map.get(map, "args_fragment"),
      call_id: Map.get(map, "call_id")
    }
  end

  defp to_event(%{"type" => "tool_call_end"} = map) do
    %{
      type: :tool_call_end,
      id: map["id"] || map["tool_call_id"],
      name: map["name"],
      args: Map.get(map, "args"),
      call_id: Map.get(map, "call_id")
    }
  end

  defp to_event(%{"type" => "response_ref", "id" => id}) do
    %{type: :response_ref, id: id}
  end

  defp to_event(%{"type" => "usage"} = map) do
    %{type: :usage, usage: Map.get(map, "usage", %{})}
  end

  defp to_event(%{"type" => "done"} = map) do
    %{
      type: :done,
      status: decode_status(Map.get(map, "status")),
      meta: Map.get(map, "meta", %{})
    }
  end

  defp to_event(%{"type" => "event"} = map), do: %{type: :event, payload: Map.drop(map, ["type"])}
  defp to_event(%{"type" => "error"} = map), do: %{type: :error, error: Map.get(map, "error")}
  # ignored downstream
  defp to_event(%{"type" => "meta"}), do: %{type: :event, payload: %{}}
  defp to_event(other), do: %{type: :event, payload: other}

  defp decode_status(nil), do: :completed
  defp decode_status("completed"), do: :completed
  defp decode_status("succeeded"), do: :succeeded
  defp decode_status("done"), do: :done
  defp decode_status("requires_action"), do: :requires_action
  defp decode_status(other) when is_binary(other), do: String.to_atom(other)
end
