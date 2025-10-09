defmodule Aquila.Transport.Replay do
  @moduledoc """
  Deterministic, verification-first transport that replays prerecorded
  cassette events. Used heavily in tests to avoid external HTTP calls and to
  ensure tests fail loudly when prompts change without the cassette being
  refreshed.
  """

  @behaviour Aquila.Transport

  alias Aquila.Transport.Cassette
  alias StableJason

  @doc """
  Replays a previously recorded non-streaming response and validates the prompt.

  Returns an error if the cassette is missing or if the stored metadata does
  not match the current request body.
  """
  @impl true
  def post(req), do: handle_http(:post, req)

  @impl true
  def get(req), do: handle_http(:get, req)

  @impl true
  def delete(req), do: handle_http(:delete, req)

  # Synthesizes tool_call_end events from buffered tool calls and invokes the callback
  defp synthesize_tool_call_ends(tool_calls, callback, with_logging \\ true) do
    Enum.each(tool_calls, fn {_id, call} ->
      args_json = Enum.join(call.fragments, "")

      args =
        case Jason.decode(args_json) do
          {:ok, decoded} ->
            decoded

          {:error, error} ->
            if with_logging do
              require Logger
              Logger.error("Failed to decode tool args JSON: #{inspect(error)}")
              Logger.error("Args JSON was: #{inspect(args_json)}")
              Logger.error("Fragments were: #{inspect(call.fragments)}")
            end

            %{}
        end

      tool_call_end = %{
        type: :tool_call_end,
        id: call.id,
        name: call.name,
        args: args,
        call_id: call.id
      }

      if with_logging do
        require Logger

        Logger.debug(
          "Replay: Synthesizing tool_call_end for #{call.name} with args: #{inspect(args)}"
        )
      end

      callback.(tool_call_end)

      if with_logging do
        require Logger
        Logger.debug("Replay: tool_call_end callback completed")
      end
    end)
  end

  # Deduplicates consecutive done events with the same status
  # This handles cassettes that have duplicate "completed" done events
  defp deduplicate_done_events(stream) do
    stream
    |> Stream.transform(nil, fn line, last_done ->
      case Jason.decode(line) do
        {:ok, %{"type" => "done", "status" => status}} ->
          if status == last_done do
            # Skip duplicate
            {[], last_done}
          else
            # Emit and track
            {[line], status}
          end

        _ ->
          # Not a done event, emit it
          {[line], last_done}
      end
    end)
  end

  @doc """
  Streams recorded SSE events to the provided callback.

  Each JSONL line is decoded into the normalised event map expected by the
  engine. Prompt mismatches raise with guidance on re-recording the cassette.
  """
  @impl true
  def stream(%{opts: opts} = req, callback) when is_function(callback, 1) do
    with {:ok, cassette} <- fetch_cassette(opts) do
      request_id = Cassette.next_index(cassette, opts)
      verify_prompt!(req, cassette, request_id, :post)

      # Buffer tool calls to synthesize tool_call_end events
      # State: {tool_calls_map, current_tool_id, pending_done_event}
      {tool_calls, _, pending_done} =
        cassette
        |> Cassette.sse_path()
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.filter(&matches_request_id?(&1, request_id))
        |> deduplicate_done_events()
        |> Enum.reduce({%{}, nil, nil}, fn line, {tool_calls_acc, current_id, buffered_done} ->
          case Jason.decode!(line) do
            %{"type" => "meta"} ->
              {tool_calls_acc, current_id, buffered_done}

            %{"type" => "tool_call", "id" => id, "name" => name} = event
            when not is_nil(id) and not is_nil(name) ->
              # Start tracking this tool call
              updated_calls = Map.put(tool_calls_acc, id, %{id: id, name: name, fragments: []})
              event |> to_event() |> callback.()
              {updated_calls, id, buffered_done}

            %{"type" => "tool_call", "args_fragment" => fragment} = event
            when not is_nil(fragment) ->
              # Accumulate fragment for the current tool call
              # Use call_id if present, otherwise use current_id
              target_id = Map.get(event, "call_id") || current_id

              updated_calls =
                if target_id do
                  Map.update(tool_calls_acc, target_id, %{fragments: [fragment]}, fn call ->
                    %{call | fragments: call.fragments ++ [fragment]}
                  end)
                else
                  tool_calls_acc
                end

              event |> to_event() |> callback.()
              {updated_calls, current_id, buffered_done}

            %{"type" => "done", "status" => "requires_action"} = event ->
              # Don't emit the done event yet - we need to synthesize tool_call_end first
              {tool_calls_acc, current_id, event}

            %{"type" => "done"} = event ->
              # Process done event (duplicates already filtered out by deduplicate_done_events)
              if buffered_done do
                # Synthesize tool_call_end events for all buffered tool calls
                synthesize_tool_call_ends(tool_calls_acc, callback)

                # Now emit the buffered done event
                buffered_done |> to_event() |> callback.()

                # Clear state after processing
                {%{}, nil, nil}
              else
                # No buffered done, just emit the event normally
                event |> to_event() |> callback.()
                {tool_calls_acc, current_id, nil}
              end

            event ->
              # Check if we just buffered a requires_action done event
              if buffered_done do
                # Synthesize tool_call_end events for all buffered tool calls
                synthesize_tool_call_ends(tool_calls_acc, callback)

                # Now emit the done event
                buffered_done |> to_event() |> callback.()

                # Emit the current event
                event |> to_event() |> callback.()

                # Clear state after processing
                {%{}, nil, nil}
              else
                # No buffered done, just emit the event normally
                event |> to_event() |> callback.()
                {tool_calls_acc, current_id, nil}
              end
          end
        end)

      # If we ended with a buffered done event, emit it now
      if tool_calls != %{} and pending_done do
        synthesize_tool_call_ends(tool_calls, callback, false)
        pending_done |> to_event() |> callback.()
      end

      {:ok, make_ref()}
    else
      :no_cassette -> {:error, :missing_cassette}
    end
  end

  defp matches_request_id?(line, request_id) do
    case Jason.decode(line) do
      {:ok, %{"request_id" => ^request_id}} -> true
      _ -> false
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
        cond do
          !method_matches?(meta, method) ->
            path = Cassette.meta_path(cassette)
            raise_method_mismatch(path, method, meta)

          bodies_match?(meta, body) ->
            :ok

          true ->
            path = Cassette.meta_path(cassette)

            raise_prompt_mismatch(path, meta, body)
        end

      {:error, {:meta_missing, path, _}} ->
        raise "Cassette metadata missing at #{path}."

      {:error, reason} ->
        raise "Unable to read cassette metadata: #{inspect(reason)}"
    end
  end

  defp method_matches?(%{"method" => nil}, method), do: method == :post

  defp method_matches?(%{"method" => recorded}, method) when is_binary(recorded) do
    recorded == Atom.to_string(method)
  end

  defp method_matches?(%{"method" => recorded}, method) when is_atom(recorded) do
    Atom.to_string(recorded) == Atom.to_string(method)
  end

  defp method_matches?(_, :post), do: true
  defp method_matches?(_, _method), do: false

  defp bodies_match?(meta, body) do
    case Map.fetch(meta, "body") do
      {:ok, recorded_body} ->
        canonical_body(recorded_body) == canonical_body(body)

      :error ->
        true
    end
  end

  defp canonical_body(nil), do: Cassette.canonical_term(:no_body)
  defp canonical_body(body), do: body |> normalize_body() |> Cassette.canonical_term()

  defp raise_prompt_mismatch(path, meta, body) do
    recorded_body = Map.get(meta, "body")
    diff = generate_body_diff(recorded_body, body)

    message =
      [
        "Cassette prompt mismatch for request #{meta["request_id"]} in #{path}.",
        "Recorded request body no longer matches the current request.",
        "",
        "Diff:",
        diff,
        "",
        "Remove the cassette files and re-record."
      ]
      |> Enum.join("\n")

    raise RuntimeError, message
  end

  defp generate_body_diff(old_body, new_body) do
    old_json = old_body |> normalize_for_diff() |> Jason.encode!(pretty: true)
    new_json = new_body |> normalize_for_diff() |> Jason.encode!(pretty: true)

    old_lines = String.split(old_json, "\n")
    new_lines = String.split(new_json, "\n")

    List.myers_difference(old_lines, new_lines)
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &"  #{&1}")
      {:del, lines} -> Enum.map(lines, &"- #{&1}")
      {:ins, lines} -> Enum.map(lines, &"+ #{&1}")
    end)
    |> Enum.take(100)
    |> Enum.join("\n")
  end

  defp normalize_for_diff(body) do
    case normalize_body(body) do
      nil ->
        nil

      value when is_map(value) or is_list(value) ->
        value
        |> StableJason.encode!(sorter: :asc)
        |> Jason.decode!()

      other ->
        other
    end
  end

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
