defmodule Aquila.LiveViewTest do
  use ExUnit.Case, async: true

  # Create a test LiveView module that uses the Aquila.LiveView macro
  defmodule TestLive do
    use Aquila.LiveView,
      supervisor: TestTaskSupervisor,
      pubsub: TestPubSub,
      persistence: TestPersistence,
      timeout: 30_000,
      forward_to_component: {TestComponent, :test_id}

    defstruct [:socket]

    def new_socket(assigns \\ %{}) do
      %{assigns: assigns}
    end
  end

  describe "Aquila.LiveView macro" do
    test "generates aquila_config/0 function with all options" do
      config = TestLive.aquila_config()

      assert config.supervisor == TestTaskSupervisor
      assert config.pubsub == TestPubSub
      assert config.persistence == TestPersistence
      assert config.timeout == 30_000
      assert config.forward_to_component == {TestComponent, :test_id}
    end

    test "generates handle_info for aquila_stream_delta" do
      socket = TestLive.new_socket()

      assert {:noreply, ^socket} =
               TestLive.handle_info({:aquila_stream_delta, "session_123", "content"}, socket)
    end

    test "generates handle_info for aquila_stream_tool_call start (ignored)" do
      socket = TestLive.new_socket()
      metadata = %{name: "test_tool"}

      assert {:noreply, ^socket} =
               TestLive.handle_info(
                 {:aquila_stream_tool_call, "session_123", :start, metadata},
                 socket
               )
    end

    test "generates handle_info for aquila_stream_usage" do
      socket = TestLive.new_socket()
      usage = %{prompt_tokens: 10, completion_tokens: 20}

      assert {:noreply, ^socket} =
               TestLive.handle_info({:aquila_stream_usage, "session_123", usage}, socket)
    end

    test "generates handle_info for aquila_stream_complete" do
      socket = TestLive.new_socket()

      assert {:noreply, ^socket} =
               TestLive.handle_info({:aquila_stream_complete, "session_123"}, socket)
    end

    test "generates handle_info for aquila_stream_error" do
      socket = TestLive.new_socket()

      assert {:noreply, ^socket} =
               TestLive.handle_info({:aquila_stream_error, "session_123", :timeout}, socket)
    end

    test "handles legacy tool call format" do
      socket = TestLive.new_socket()

      assert {:noreply, ^socket} =
               TestLive.handle_info(
                 {:aquila_stream_tool_call, "session_123", "tool_name", "result"},
                 socket
               )
    end

    test "handles tool call end event with metadata" do
      socket = TestLive.new_socket()
      metadata = %{name: "test_tool", output: "result"}

      assert {:noreply, ^socket} =
               TestLive.handle_info(
                 {:aquila_stream_tool_call, "session_123", :end, metadata},
                 socket
               )
    end
  end

  describe "Aquila.LiveView without optional params" do
    defmodule MinimalTestLive do
      use Aquila.LiveView,
        supervisor: TestTaskSupervisor,
        pubsub: TestPubSub

      defstruct [:socket]
    end

    test "generates config with defaults" do
      config = MinimalTestLive.aquila_config()

      assert config.supervisor == TestTaskSupervisor
      assert config.pubsub == TestPubSub
      assert config.persistence == nil
      assert config.timeout == 60_000
      assert config.forward_to_component == nil
    end
  end
end
