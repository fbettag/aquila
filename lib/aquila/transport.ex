defmodule Aquila.Transport do
  @moduledoc """
  Behaviour describing the contract for HTTP transports.

  Implementations are responsible for POST requests and streaming responses
  from OpenAI-compatible endpoints. Streaming events should be normalised to
  the lightweight maps documented below (`:delta`, `:done`, `:tool_call`,
  etc.) so that `Aquila.Engine` can remain oblivious to provider-specific wire
  formats.
  """

  @type req :: %{
          required(:endpoint) => :responses | :chat,
          required(:url) => String.t(),
          optional(:body) => map() | nil,
          optional(:headers) => [{String.t(), String.t()}],
          optional(:opts) => keyword()
        }

  @type stream_ref :: reference()
  @typedoc "Normalised streaming event delivered to the engine callback."
  @type event :: map()

  @callback post(req()) :: {:ok, map()} | {:error, term()}
  @callback get(req()) :: {:ok, map()} | {:error, term()}
  @callback delete(req()) :: {:ok, map()} | {:error, term()}
  @callback stream(req(), (event() -> any())) :: {:ok, stream_ref()} | {:error, term()}
end
