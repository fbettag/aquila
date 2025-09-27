defmodule Aquila.SinkTest do
  use ExUnit.Case, async: true

  alias Aquila.Sink

  describe "pid/2" do
    test "creates pid sink with default opts" do
      sink = Sink.pid(self())
      assert {:pid, pid, []} = sink
      assert pid == self()
    end

    test "creates pid sink with opts" do
      sink = Sink.pid(self(), with_ref: false)
      assert {:pid, _, opts} = sink
      assert opts == [with_ref: false]
    end
  end

  describe "fun/1" do
    test "creates function sink" do
      fun = fn _event, _ref -> :ok end
      sink = Sink.fun(fun)
      assert {:fun, ^fun} = sink
    end
  end

  describe "collector/2" do
    test "creates collector sink with default opts" do
      sink = Sink.collector(self())
      assert {:collector, pid, []} = sink
      assert pid == self()
    end

    test "creates collector sink with opts" do
      sink = Sink.collector(self(), transform: &Function.identity/1)
      assert {:collector, _, opts} = sink
      assert Keyword.has_key?(opts, :transform)
    end
  end

  describe "notify/3 with :ignore" do
    test "does nothing" do
      ref = make_ref()
      assert :ok = Sink.notify(:ignore, {:chunk, "test"}, ref)
    end
  end

  describe "notify/3 with :fun sink" do
    test "calls function with event and ref" do
      ref = make_ref()
      test_pid = self()

      fun = fn event, received_ref ->
        send(test_pid, {:called, event, received_ref})
      end

      Sink.notify({:fun, fun}, {:chunk, "hello"}, ref)

      assert_receive {:called, {:chunk, "hello"}, ^ref}
    end
  end

  describe "notify/3 with :pid sink" do
    test "sends chunk message with ref" do
      ref = make_ref()
      Sink.notify({:pid, self(), []}, {:chunk, "test"}, ref)
      assert_receive {:aquila_chunk, "test", ^ref}
    end

    test "sends chunk message without ref when with_ref: false" do
      ref = make_ref()
      Sink.notify({:pid, self(), [with_ref: false]}, {:chunk, "test"}, ref)
      assert_receive {:aquila_chunk, "test"}
      refute_receive {:aquila_chunk, "test", ^ref}
    end

    test "sends done message with ref" do
      ref = make_ref()
      Sink.notify({:pid, self(), []}, {:done, "final", %{status: :done}}, ref)
      assert_receive {:aquila_done, "final", %{status: :done}, ^ref}
    end

    test "sends done message without ref when with_ref: false" do
      ref = make_ref()
      Sink.notify({:pid, self(), [with_ref: false]}, {:done, "final", %{}}, ref)
      assert_receive {:aquila_done, "final", %{}}
    end

    test "sends error message with ref" do
      ref = make_ref()
      Sink.notify({:pid, self(), []}, {:error, :timeout}, ref)
      assert_receive {:aquila_error, :timeout, ^ref}
    end

    test "sends error message without ref when with_ref: false" do
      ref = make_ref()
      Sink.notify({:pid, self(), [with_ref: false]}, {:error, :boom}, ref)
      assert_receive {:aquila_error, :boom}
    end

    test "sends generic event message" do
      ref = make_ref()
      event_data = %{type: :custom, data: "something"}
      Sink.notify({:pid, self(), []}, {:event, event_data}, ref)
      assert_receive {:aquila_event, ^event_data, ^ref}
    end

    test "sends tool_call_start event" do
      ref = make_ref()
      event_data = %{type: :tool_call_start, id: "call_123", name: "test"}
      Sink.notify({:pid, self(), []}, {:event, event_data}, ref)
      assert_receive {:aquila_tool_call, :start, ^event_data, ^ref}
    end

    test "sends tool_call_start without ref" do
      ref = make_ref()
      event_data = %{type: :tool_call_start, id: "call_123"}
      Sink.notify({:pid, self(), [with_ref: false]}, {:event, event_data}, ref)
      assert_receive {:aquila_tool_call, :start, ^event_data}
    end

    test "sends tool_call_result event" do
      ref = make_ref()
      event_data = %{type: :tool_call_result, id: "call_123", result: "done"}
      Sink.notify({:pid, self(), []}, {:event, event_data}, ref)
      assert_receive {:aquila_tool_call, :result, ^event_data, ^ref}
    end

    test "sends tool_call_result without ref" do
      ref = make_ref()
      event_data = %{type: :tool_call_result, id: "call_123"}
      Sink.notify({:pid, self(), [with_ref: false]}, {:event, event_data}, ref)
      assert_receive {:aquila_tool_call, :result, ^event_data}
    end

    test "applies transform function" do
      ref = make_ref()

      transform = fn
        {:aquila_chunk, chunk, ref} -> {:custom_chunk, String.upcase(chunk), ref}
        other -> other
      end

      Sink.notify({:pid, self(), [transform: transform]}, {:chunk, "hello"}, ref)
      assert_receive {:custom_chunk, "HELLO", ^ref}
    end

    test "transform can return nil to skip message" do
      ref = make_ref()
      transform = fn _ -> nil end

      Sink.notify({:pid, self(), [transform: transform]}, {:chunk, "hello"}, ref)
      refute_receive {:aquila_chunk, _, _}
    end
  end

  describe "notify/3 with :collector sink" do
    test "sends chunk message with ref" do
      ref = make_ref()
      Sink.notify({:collector, self(), []}, {:chunk, "test"}, ref)
      assert_receive {:aquila_chunk, "test", ^ref}
    end

    test "sends chunk message without ref when with_ref: false" do
      ref = make_ref()
      Sink.notify({:collector, self(), [with_ref: false]}, {:chunk, "test"}, ref)
      assert_receive {:aquila_chunk, "test"}
    end

    test "sends done message" do
      ref = make_ref()
      Sink.notify({:collector, self(), []}, {:done, "final", %{status: :done}}, ref)
      assert_receive {:aquila_done, "final", %{status: :done}, ^ref}
    end

    test "sends error message" do
      ref = make_ref()
      Sink.notify({:collector, self(), []}, {:error, :failed}, ref)
      assert_receive {:aquila_error, :failed, ^ref}
    end

    test "sends event message" do
      ref = make_ref()
      event_data = %{type: :usage, tokens: 100}
      Sink.notify({:collector, self(), []}, {:event, event_data}, ref)
      assert_receive {:aquila_event, ^event_data, ^ref}
    end

    test "applies transform function" do
      ref = make_ref()

      transform = fn
        {:aquila_done, text, meta, ref} -> {:done_transformed, text, meta, ref}
        other -> other
      end

      Sink.notify({:collector, self(), [transform: transform]}, {:done, "text", %{}}, ref)
      assert_receive {:done_transformed, "text", %{}, ^ref}
    end

    test "transform can filter messages" do
      ref = make_ref()
      transform = fn _ -> nil end

      Sink.notify({:collector, self(), [transform: transform]}, {:chunk, "ignore"}, ref)
      refute_receive _
    end
  end
end
