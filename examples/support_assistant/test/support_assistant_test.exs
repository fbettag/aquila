defmodule SupportAssistantTest do
  use ExUnit.Case, async: true

  test "streams a grounded policy response through the tool loop" do
    assert {:ok, ref} =
             SupportAssistant.stream("Refund?",
               transport: SupportAssistant.DemoTransport,
               api_key: "offline",
               model: "offline"
             )

    assert_receive {:aquila_done, text, _meta, ^ref}, 5_000
    assert text =~ "local-policy/refunds"
  end

  test "unknown policy cannot trigger an account action" do
    assert {:error, _} = SupportAssistant.lookup(%{"topic" => "delete-account"}, %{})
    assert %{source: "local-policy/access"} = SupportAssistant.lookup(%{"topic" => "access"}, %{})
  end

  defmodule FailureTransport do
    @behaviour Aquila.Transport
    def post(_), do: {:error, :offline}
    def get(_), do: {:error, :offline}
    def delete(_), do: {:error, :offline}
    def stream(_, _), do: {:error, :offline}
  end

  test "transport failures reach the caller" do
    case SupportAssistant.stream("Refund?",
           transport: FailureTransport,
           api_key: "offline",
           model: "offline"
         ) do
      {:error, _} -> :ok
      {:ok, ref} -> assert_receive {:aquila_error, _, ^ref}, 5_000
    end
  end
end
