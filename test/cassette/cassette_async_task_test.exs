defmodule AquilaCassetteAsyncTaskTest do
  @moduledoc """
  Tests for cassette context propagation across async Task boundaries.

  These tests ensure cassettes work correctly in complex scenarios like:
  - Nested Task.async calls
  - Tasks spawned from processes with different group leaders
  - Phoenix LiveView test scenarios where Tasks are spawned from LiveView processes
  """
  use ExUnit.Case, async: false
  use Aquila.Cassette

  alias Aquila.Cassette
  alias Aquila.CaptureTransport

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

  test "single level Task.async can access cassette" do
    aquila_cassette "single-task" do
      task = Task.async(fn -> Cassette.current() end)
      assert Task.await(task) == {"single-task", []}
    end
  end

  test "nested Task.async can access cassette (LiveView scenario)" do
    aquila_cassette "nested-task" do
      # Simulate LiveView spawning a Task
      outer_task =
        Task.async(fn ->
          # Inside first Task, spawn another Task (like Engine.start_stream does)
          inner_task =
            Task.async(fn ->
              # This is where Aquila.stream would be called
              Cassette.current()
            end)

          Task.await(inner_task)
        end)

      result = Task.await(outer_task)
      assert result == {"nested-task", []}, "Nested task should be able to access cassette"
    end
  end

  # Note: The full end-to-end test with Aquila.stream is tested in integration tests.
  # This test suite focuses on cassette lookup across Task boundaries.

  test "Task spawned from different process can still access cassette" do
    aquila_cassette "cross-process" do
      # Spawn an intermediary process (simulating LiveView)
      parent = self()

      _intermediary_pid =
        spawn(fn ->
          # This process might have a different group leader
          # Spawn a Task from here
          task =
            Task.async(fn ->
              cassette = Cassette.current()
              send(parent, {:cassette_result, cassette})
            end)

          Task.await(task)
        end)

      # Wait for the result
      assert_receive {:cassette_result, {"cross-process", []}}, 1000
    end
  end

  test "deeply nested Tasks can access cassette" do
    aquila_cassette "deeply-nested" do
      task1 =
        Task.async(fn ->
          Task.async(fn ->
            Task.async(fn ->
              Cassette.current()
            end)
            |> Task.await()
          end)
          |> Task.await()
        end)

      result = Task.await(task1)
      assert result == {"deeply-nested", []}, "Deeply nested tasks should access cassette"
    end
  end
end
