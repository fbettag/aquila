defmodule Aquila.Transport.OpenAI.Responses do
  @moduledoc """
  Responses API event normalization for streaming responses.

  Handles:
  - Response creation and completion events
  - Output text deltas and chunks
  - Function call (tool) deltas and completion
  - Deep research events
  - Built-in tool events (code_interpreter, file_search, etc.)
  """

  @doc """
  Normalizes a Responses API streaming event into engine-compatible format.

  Takes parsed JSON payload and callback function, emits normalized events.
  """
  def normalize(payload, callback) do
    events = normalize_responses(payload)
    Enum.each(events, &callback.(&1))
    events
  end

  # Response lifecycle events

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

  # Function call events

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

  # Text output events

  defp normalize_responses(%{"type" => "response.output_text.chunk", "text" => text}) do
    [%{type: :delta, content: text}]
  end

  # Progress and metadata events

  defp normalize_responses(%{"type" => "response.in_progress"} = payload) do
    [%{type: :event, payload: deep_research_payload(payload)}]
  end

  defp normalize_responses(%{"type" => "response.usage.delta", "usage" => usage}) do
    [%{type: :usage, usage: usage}]
  end

  # Error events

  defp normalize_responses(%{"type" => "response.error", "error" => error}) do
    [%{type: :error, error: error}]
  end

  # Generic event routing

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

  # Output normalization helpers

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

  # Built-in tool helpers

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

  # Deep research helpers

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

  # Utility helpers

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
