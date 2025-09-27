defmodule Aquila.CaptureTransport do
  @moduledoc """
  Test transport that captures requests and sends them to the test process.
  """
  @behaviour Aquila.Transport

  def post(_req), do: {:ok, %{"ok" => true}}
  def get(_req), do: {:ok, %{"ok" => true}}
  def delete(_req), do: {:ok, %{"ok" => true}}

  def stream(req, callback) do
    send(self(), {:stream_request, req})
    callback.(%{type: :done, status: :completed, meta: %{}})
    {:ok, make_ref()}
  end
end
