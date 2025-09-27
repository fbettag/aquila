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
  """
  @spec current() :: {String.t(), keyword()} | nil
  def current do
    Process.get(@cassette_key) ||
      case :persistent_term.get(group_key(), :none) do
        :none -> nil
        value -> value
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
