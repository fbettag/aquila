defmodule Aquila.Endpoint do
  @moduledoc """
  Endpoint selection helpers for OpenAI-compatible transports.

  The Responses API is preferred whenever the base URL points at
  `api.openai.com` and the target model is known to support it. Fallback to
  Chat Completions is automatic for custom base URLs or for models that are
  chat-only.
  """

  @responses_models ~w(gpt-4o gpt-4.1 gpt-4.1-mini gpt-4o-mini gpt-4.1-nano)a

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
  Default heuristic for endpoint selection.

  Prefers the Responses API when the base URL ends in `/responses`, when the
  configured model is in the supported set, or when the host matches the
  canonical OpenAI domain. Any other combination falls back to Chat
  Completions.
  """
  @spec default(keyword()) :: endpoint()
  def default(opts) do
    base_url = to_string(opts[:base_url] || config(:base_url) || "https://api.openai.com/v1")
    model = opts[:model] |> model_to_string()

    cond do
      String.ends_with?(base_url, "/responses") -> :responses
      responses_model?(model) and base_url =~ "api.openai.com" -> :responses
      true -> :chat
    end
  end

  @doc false
  @spec responses_model?(String.t()) :: boolean()
  def responses_model?(model) when is_binary(model) do
    cleaned = String.replace(model, ~r/-latest$/, "")
    cleaned in Enum.map(@responses_models, &to_string/1)
  end

  defp model_to_string(nil), do: to_string(config(:default_model) || "gpt-4o-mini")
  defp model_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp model_to_string(model), do: to_string(model)

  defp config(key) do
    Application.get_env(:aquila, :openai, []) |> Keyword.get(key)
  end
end
