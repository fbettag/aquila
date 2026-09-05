defmodule SupportAssistant.DemoTransport do
  @moduledoc "Deterministic offline model substitute. Exercises Aquila's actual tool loop and sink."
  @behaviour Aquila.Transport
  def post(_), do: {:error, :stream_only}
  def get(_), do: {:error, :unsupported}
  def delete(_), do: {:error, :unsupported}

  def stream(request, on_event) do
    messages = request.body[:messages] || request.body["messages"] || []
    tool_result = Enum.find(messages, fn m -> (m[:role] || m["role"]) == "tool" end)

    if tool_result do
      on_event.(%{
        type: :delta,
        content: "Refund requests need human review. Source: local-policy/refunds."
      })

      on_event.(%{type: :done, meta: %{}})
    else
      on_event.(%{
        type: :tool_call,
        id: "policy-1",
        name: "lookup_policy",
        args_fragment: "{\"topic\":\"refunds\"}"
      })

      on_event.(%{type: :tool_call_end, id: "policy-1"})
      on_event.(%{type: :done, status: :requires_action, meta: %{}})
    end

    {:ok, make_ref()}
  end
end
