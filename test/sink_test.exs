defmodule Aquila.SinkTest do
  use ExUnit.Case, async: true

  alias Aquila.Sink

  test "pid sink sends messages with ref" do
    sink = Sink.pid(self())
    ref = make_ref()

    Sink.notify(sink, {:chunk, "helo"}, ref)
    Sink.notify(sink, {:done, "full", %{}}, ref)

    assert_received {:aquila_chunk, "helo", ^ref}
    assert_received {:aquila_done, "full", %{}, ^ref}
  end

  test "collector omits ref when configured" do
    sink = Sink.collector(self(), with_ref: false)
    ref = make_ref()

    Sink.notify(sink, {:event, %{foo: :bar}}, ref)
    Sink.notify(sink, {:error, :oops}, ref)

    assert_received {:aquila_event, %{foo: :bar}}
    assert_received {:aquila_error, :oops}
  end

  test "fun sink invokes callback" do
    parent = self()

    fun = fn event, ref -> send(parent, {:fun_sink, event, ref}) end
    sink = Sink.fun(fun)
    ref = make_ref()

    Sink.notify(sink, {:done, "text", %{}}, ref)

    assert_received {:fun_sink, {:done, "text", %{}}, ^ref}
  end
end
