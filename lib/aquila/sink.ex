defmodule Aquila.Sink do
  @moduledoc """
  Collection of sink helpers used during streaming.

  A sink receives streaming events (`:chunk`, `:done`, `:event`, `:error`)
  along with the stream reference so callers can correlate concurrent
  streams when desired. See the "Streaming and Sinks" guide for a deeper
  walkthrough.
  """

  @type event ::
          {:chunk, binary()}
          | {:done, binary(), map()}
          | {:event, map()}
          | {:error, term()}

  @type t ::
          {:pid, pid(), keyword()}
          | {:fun, (event(), reference() -> any())}
          | {:collector, pid(), keyword()}
          | :ignore

  @doc """
  Sends streaming notifications to the given process.

  Messages follow one of four shapes:

    * `{:aquila_chunk, chunk, ref}` – incremental content fragment
    * `{:aquila_event, map, ref}` – metadata/tool related events
    * `{:aquila_done, text, meta, ref}` – final aggregated response
    * `{:aquila_error, reason, ref}` – transport or orchestration failure

  Set `with_ref: false` to omit the `ref` element from each tuple.

  ## Examples

      {:ok, ref} = Aquila.stream("Ping", sink: Aquila.Sink.pid(self()))
      assert_receive {:aquila_chunk, _chunk, ^ref}
  """
  @spec pid(pid(), keyword()) :: t()
  def pid(pid \\ self(), opts \\ []) when is_pid(pid), do: {:pid, pid, opts}

  @doc """
  Wraps a two-arity function sink.

  The function is invoked as `fun.(event, ref)` with the event tuple
  described above.

  ## Examples

      fun = fn
        {:chunk, chunk}, ref -> IO.inspect({:chunk, ref, chunk})
        {:done, text, _meta}, ref -> IO.inspect({:done, ref, text})
      end

      Aquila.stream("Hello", sink: Aquila.Sink.fun(fun))
  """
  @spec fun((event(), reference() -> any())) :: t()
  def fun(fun) when is_function(fun, 2), do: {:fun, fun}

  @doc """
  Returns a sink that replays events to the calling process using a
  standard tuple format. Useful for tests that need deterministic ordering
  by associating events with a unique reference.

  ## Examples

      sink = Aquila.Sink.collector(self())
      {:ok, ref} = Aquila.stream("Hello", sink: sink)
      assert_receive {:aquila_done, _text, _meta, ^ref}
  """
  @spec collector(pid(), keyword()) :: t()
  def collector(owner \\ self(), opts \\ []) when is_pid(owner), do: {:collector, owner, opts}

  @doc false
  @spec notify(t(), event(), reference()) :: :ok
  def notify(:ignore, _event, _ref), do: :ok
  def notify({:fun, fun}, event, ref), do: fun.(event, ref)

  def notify({:pid, pid, opts}, event, ref) do
    message = format(event, ref, opts)
    message = maybe_transform(message, opts)
    if message, do: send(pid, message)
    :ok
  end

  def notify({:collector, pid, opts}, event, ref) do
    message = format(event, ref, opts)
    message = maybe_transform(message, opts)
    if message, do: send(pid, message)
    :ok
  end

  defp format({:chunk, chunk}, ref, opts) do
    payload = {:aquila_chunk, chunk, ref}
    maybe_with_ref(payload, opts)
  end

  defp format({:done, text, meta}, ref, opts) do
    payload = {:aquila_done, text, meta, ref}
    maybe_with_ref(payload, opts)
  end

  defp format({:event, %{type: :tool_call_start} = map}, ref, opts) do
    payload = {:aquila_tool_call, :start, map, ref}
    maybe_with_ref(payload, opts)
  end

  defp format({:event, %{type: :tool_call_result} = map}, ref, opts) do
    payload = {:aquila_tool_call, :result, map, ref}
    maybe_with_ref(payload, opts)
  end

  defp format({:event, map}, ref, opts) do
    payload = {:aquila_event, map, ref}
    maybe_with_ref(payload, opts)
  end

  defp format({:error, reason}, ref, opts) do
    payload = {:aquila_error, reason, ref}
    maybe_with_ref(payload, opts)
  end

  defp maybe_with_ref({tag, value, ref}, opts) do
    if Keyword.get(opts, :with_ref, true) do
      {tag, value, ref}
    else
      {tag, value}
    end
  end

  defp maybe_with_ref({tag, status, value, ref}, opts) when is_atom(status) do
    # Handle {:aquila_tool_call, :start/:result, data, ref}
    if Keyword.get(opts, :with_ref, true) do
      {tag, status, value, ref}
    else
      {tag, status, value}
    end
  end

  defp maybe_with_ref({tag, value, meta, ref}, opts) do
    if Keyword.get(opts, :with_ref, true) do
      {tag, value, meta, ref}
    else
      {tag, value, meta}
    end
  end

  defp maybe_transform(message, opts) do
    case Keyword.get(opts, :transform) do
      nil -> message
      fun when is_function(fun, 1) -> fun.(message)
    end
  end
end
