defmodule Aquila.Endpoint do
  @moduledoc """
  Endpoint selection helpers for OpenAI-compatible transports.

  Callers opt into the Responses API explicitly by passing `endpoint: :responses`
  (or supplying a custom `:endpoint_selector`). When neither is provided Aquila
  defaults to the Chat Completions endpoint.
  """

  @responses_models ~w(gpt-4o gpt-4.1 gpt-4.1-mini gpt-4.1-nano)a

  @type endpoint :: :responses | :chat

  @doc """
  Chooses the appropriate endpoint using explicit options first and then the
  default heuristic.

  Options are inspected in the following order:

  1. `:endpoint` – explicit override (`:responses` or `:chat`).
  2. `:endpoint_selector` – custom callback that receives the full options.
  3. Fallback to `default/1`.
  """
  @spec choose(keyword()) :: endpoint()
  def choose(opts) do
    cond do
      endpoint = opts[:endpoint] -> endpoint
      selector = opts[:endpoint_selector] -> selector.(opts)
      true -> default(opts)
    end
  end

  @doc """
  Default endpoint selection when no explicit override is provided.
  """
  @spec default(keyword()) :: endpoint()
  def default(_opts), do: :chat

  @doc false
  @spec responses_model?(String.t()) :: boolean()
  def responses_model?(model) when is_binary(model) do
    cleaned = String.replace(model, ~r/-latest$/, "")
    cleaned in Enum.map(@responses_models, &to_string/1)
  end
end
