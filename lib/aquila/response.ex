defmodule Aquila.Response do
  @moduledoc """
  Final response returned by `Aquila.ask/2`.

  Contains the aggregated text, transport metadata (model, usage, response
  identifiers), and the full raw payload for callers that need to inspect
  provider-specific fields.
  """

  defstruct text: "", meta: %{}, raw: %{}

  @type t :: %__MODULE__{text: String.t(), meta: map(), raw: map()}

  @doc """
  Builds a response struct.

  Accepts the accumulated text chunks, a metadata map, and the raw provider
  payload. Non-binary text is normalised to a binary for convenience.
  """
  @spec new(iodata(), map(), map()) :: t()
  def new(text, meta \\ %{}, raw \\ %{}) do
    %__MODULE__{text: IO.iodata_to_binary(text), meta: meta, raw: raw}
  end

  @doc """
  Updates `:meta` with the result of applying `fun`.

  Useful for adding telemetry or application-specific metadata without
  touching the rest of the response.
  """
  @spec update_meta(t(), (map() -> map())) :: t()
  def update_meta(%__MODULE__{} = response, fun) when is_function(fun, 1) do
    %{response | meta: fun.(response.meta)}
  end
end
