defmodule Aquila.Cassette do
  @moduledoc """
  Helpers for scoping default recorder cassettes during tests.

  Wrap test logic in `aquila_cassette/3` (or call `with/3`) to set a default
  cassette name and options for all Aquila calls executed within the block. The
  value is stored in the process dictionary and automatically restored, so
  nested calls work as expected.
  """

  @cassette_key :"aquila:cassette"
  @group_key :"aquila:cassette:group"

  defmacro __using__(_opts) do
    quote do
      import Aquila.Cassette, only: [aquila_cassette: 2, aquila_cassette: 3]
    end
  end

  @doc """
  Runs the given block with the cassette configured for the current process.

  Options passed to the macro behave like defaults: they will be merged into
  Aquila call options only when the call does not already provide the same key.
  """
  defmacro aquila_cassette(name, opts \\ [], do: block) do
    quote do
      Aquila.Cassette.with(unquote(name), unquote(opts), fn -> unquote(block) end)
    end
  end

  @doc """
  Executes `fun` while the provided cassette is active.

  Returns the value of `fun`. The previous cassette (if any) is restored after
  the function completes.
  """
  @spec with(String.t() | atom(), keyword(), (-> result)) :: result when result: var
  def with(name, opts \\ [], fun) when is_function(fun, 0) do
    entry = normalize_entry(name, opts)
    cassette_name = elem(entry, 0)

    # Reset the cassette index for this cassette to ensure clean state
    Aquila.Transport.Cassette.reset_index(cassette_name)

    group_id = group_key()
    previous = {Process.get(@cassette_key), :persistent_term.get(group_id, :none)}

    Process.put(@cassette_key, entry)
    :persistent_term.put(group_id, entry)

    try do
      fun.()
    after
      restore(previous, group_id)
    end
  end

  @doc """
  Returns the currently configured cassette tuple `{name, opts}` for this
  process, or `nil` when none is active.

  This function checks multiple locations to find the active cassette:
  1. Current process dictionary
  2. persistent_term keyed by current process's group leader
  3. persistent_term keyed by ancestor processes' group leaders (walking up the chain)

  The ancestry walk ensures cassettes work across async Task boundaries and in
  scenarios like Phoenix LiveView tests where Tasks are spawned from processes
  with different group leaders.
  """
  @spec current() :: {String.t(), keyword()} | nil
  def current do
    Process.get(@cassette_key) || check_group_leaders()
  end

  # Check persistent_term using current and ancestor group leaders
  defp check_group_leaders do
    check_group_leader(Process.group_leader()) || check_ancestor_group_leaders()
  end

  # Check persistent_term for a specific group leader
  defp check_group_leader(group_leader) when is_pid(group_leader) do
    case :persistent_term.get({@group_key, group_leader}, :none) do
      :none -> nil
      value -> value
    end
  end

  defp check_group_leader(_), do: nil

  # Walk up the process ancestry chain checking each ancestor's group leaders
  defp check_ancestor_group_leaders do
    case get_parent_pid() do
      nil ->
        nil

      parent_pid ->
        # Get group leader of the parent process using erlang module
        current_gl = Process.group_leader()

        case :erlang.process_info(parent_pid, :group_leader) do
          {:group_leader, gl} when gl != current_gl ->
            check_group_leader(gl) || check_ancestor_from(parent_pid)

          {:group_leader, _gl} ->
            # Same group leader, continue up the chain
            check_ancestor_from(parent_pid)

          _ ->
            nil
        end
    end
  end

  # Continue checking from a specific ancestor process
  defp check_ancestor_from(pid) do
    case get_parent_pid(pid) do
      nil ->
        nil

      parent_pid ->
        case :erlang.process_info(parent_pid, :group_leader) do
          {:group_leader, gl} -> check_group_leader(gl) || check_ancestor_from(parent_pid)
          _ -> nil
        end
    end
  end

  # Get the parent PID of the current process or a specific process
  defp get_parent_pid(pid \\ self()) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        # Check for $ancestors key which is set by Task and other OTP processes
        case Keyword.get(dict, :"$ancestors") do
          [parent | _] when is_pid(parent) -> parent
          _ -> nil
        end

      nil ->
        nil
    end
  end

  @doc false
  @spec clear() :: :ok
  def clear do
    Process.delete(@cassette_key)
    :persistent_term.erase(group_key())
    :ok
  end

  defp restore({prev_proc, prev_group}, group_id) do
    case prev_proc do
      nil -> Process.delete(@cassette_key)
      value -> Process.put(@cassette_key, value)
    end

    case prev_group do
      :none -> :persistent_term.erase(group_id)
      value -> :persistent_term.put(group_id, value)
    end
  end

  defp normalize_entry(name, opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, ":opts for aquila cassette must be a keyword list"
    end

    {to_string(name), Keyword.delete(opts, :cassette)}
  end

  defp group_key, do: {@group_key, Process.group_leader()}
end
