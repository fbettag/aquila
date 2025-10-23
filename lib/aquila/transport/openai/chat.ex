defmodule Aquila.Transport.OpenAI.Chat do
  @moduledoc """
  Chat Completions API event normalization for streaming responses.

  Handles:
  - Delta content from streaming chunks
  - Tool call fragment accumulation by index
  - Finish reason mapping to engine status
  - Tool call end event synthesis when stream completes
  """

  require Logger

  @doc """
  Normalizes a Chat Completions streaming event into engine-compatible format.

  Takes the streaming state and parsed JSON payload, returns {new_state, events}.
  Events are maps with :type field and endpoint-agnostic structure.
  """
  def normalize(state, payload, callback) do
    {new_state, events} = normalize_chat(state, payload)
    Enum.each(events, &callback.(&1))
    {new_state, events}
  end

  # Main chat normalization
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

  defp atomise_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {atomise_key(k), v} end)
  end

  defp atomise_key(k) when is_atom(k), do: k
  defp atomise_key("id"), do: :id
  defp atomise_key("model"), do: :model
  defp atomise_key("reason"), do: :reason
  defp atomise_key(k) when is_binary(k), do: k
  defp atomise_key(k), do: k
end
