defmodule Aquila.OpenAIResponsesNormalizeTest do
  use ExUnit.Case, async: true

  alias Aquila.Transport.OpenAI.Responses

  defp normalize_events(payload) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    events =
      Responses.normalize(payload, fn event ->
        Agent.update(agent, &[event | &1])
      end)

    collected = Agent.get(agent, &Enum.reverse/1)
    Agent.stop(agent, :normal)
    {events, collected}
  end

  test "emits tool call events for function type tool payloads" do
    payload = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_1",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{
                "type" => "tool_call",
                "call_id" => "tool_1",
                "tool_call" => %{
                  "type" => "function",
                  "name" => "calc",
                  "arguments" => "{\"x\":1}"
                }
              }
            ]
          }
        ]
      }
    }

    {events, _} = normalize_events(payload)

    assert [
             %{type: :tool_call_end, id: "tool_1", call_id: "tool_1", args: nil, name: nil},
             %{type: :done, status: :completed, meta: meta}
           ] = events

    assert meta[:id] == "resp_1"
  end

  test "ignores events with nil type" do
    payload = %{"type" => nil}

    {events, _} = normalize_events(payload)
    assert events == []
  end

  test "decodes function call arguments with raw fallback" do
    payload = %{
      "type" => "response.function_call_arguments.done",
      "call_id" => "call_1",
      "function_call" => %{"name" => "calc"},
      "arguments" => "not json"
    }

    {events, _} = normalize_events(payload)

    assert [event] = events
    assert event.type == :tool_call_end
    assert event.args == %{"raw" => "not json"}
  end

  test "emits builtin tool events with stage" do
    payload = %{
      "type" => "response.tool_call.output_json.delta",
      "call_id" => "builtin",
      "tool_call" => %{"id" => "builtin"},
      "delta" => %{"value" => 1}
    }

    {events, _} = normalize_events(payload)

    assert [%{type: :event, payload: payload_map}] = events
    assert payload_map.stage == "delta"
    assert payload_map.source == :builtin_tool
    assert payload_map.call_id == "builtin"
  end

  test "wraps non-function output items as deep research events" do
    payload = %{
      "type" => "response.output_item.added",
      "item" => %{"type" => "summary", "content" => []}
    }

    {events, _} = normalize_events(payload)

    assert [%{type: :event, payload: payload_map}] = events
    assert payload_map.source == :deep_research
    assert payload_map.event == :output_item_added
  end

  test "emits delta for output text chunks" do
    payload = %{"type" => "response.output_text.chunk", "text" => "part"}

    {events, _} = normalize_events(payload)

    assert [%{type: :delta, content: "part"}] = events
  end

  test "captures deep research reasoning events" do
    payload = %{
      "type" => "response.reasoning.delta",
      "step" => %{"explanation" => "thinking"}
    }

    {events, _} = normalize_events(payload)

    assert [%{type: :event, payload: payload_map}] = events
    assert payload_map.source == :deep_research
    assert payload_map.event == :reasoning_delta
    step = Map.get(payload_map.data, :step) || Map.get(payload_map.data, "step")
    assert step
    assert Map.get(step, :explanation) || Map.get(step, "explanation") == "thinking"
  end
end
