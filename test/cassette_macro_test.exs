defmodule AquilaCassetteMacroTest do
  use ExUnit.Case, async: true
  use Aquila.Cassette

  alias Aquila.Cassette

  defmodule CaptureTransport do
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

  setup do
    original = Application.get_env(:aquila, :transport)
    Application.put_env(:aquila, :transport, CaptureTransport)

    on_exit(fn ->
      if original do
        Application.put_env(:aquila, :transport, original)
      else
        Application.delete_env(:aquila, :transport)
      end

      Cassette.clear()
    end)

    :ok
  end

  test "aquila_cassette macro injects cassette name" do
    aquila_cassette "macro-demo" do
      Aquila.ask("hi")
    end

    assert_received {:stream_request, %{opts: opts}}
    assert Keyword.get(opts, :cassette) == "macro-demo"
  end

  test "macro merges default cassette options" do
    aquila_cassette "macro-demo", cassette_index: 2 do
      Aquila.ask("hi")
    end

    assert_received {:stream_request, %{opts: opts}}
    assert Keyword.get(opts, :cassette_index) == 2
  end

  test "call opts override cassette defaults" do
    aquila_cassette "macro-demo", cassette_index: 1 do
      Aquila.ask("hi", cassette_index: 99)
    end

    assert_received {:stream_request, %{opts: opts}}
    assert Keyword.get(opts, :cassette_index) == 99
  end

  test "cassette restored after block" do
    aquila_cassette "outer" do
      aquila_cassette "inner" do
        assert Cassette.current() == {"inner", []}
      end

      assert Cassette.current() == {"outer", []}
    end

    refute Cassette.current()
  end

  test "cassette visible to processes sharing group leader" do
    aquila_cassette "shared" do
      task = Task.async(fn -> Cassette.current() end)
      assert Task.await(task) == {"shared", []}
    end
  end

  test "explicit cassette option bypasses macro" do
    aquila_cassette "macro-demo" do
      Aquila.ask("hi", cassette: "manual")
    end

    assert_received {:stream_request, %{opts: opts}}
    assert Keyword.get(opts, :cassette) == "manual"
  end
end
