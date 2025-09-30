defmodule Aquila.Message do
  @moduledoc """
  Chat-style message structure shared across transports.

  Provides helpers for coercing user input into normalised
  `%Aquila.Message{}` structs so that `Aquila.Engine` can operate on consistent data
  regardless of the upstream endpoint or prompt shape.
  """

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :name]

  @type role :: :system | :user | :assistant | :function
  @type t :: %__MODULE__{
          role: role(),
          content: iodata() | map(),
          name: nil | String.t()
        }

  @doc """
  Builds a new message.

  ## Options

  * `:name` – assistant/function name associated with the message.
  """
  @spec new(role(), iodata() | map(), keyword()) :: t()
  def new(role, content, opts \\ []) when role in [:system, :user, :assistant, :function] do
    struct!(__MODULE__, role: role, content: content, name: Keyword.get(opts, :name))
  end

  @doc """
  Converts permissive values into `%Aquila.Message{}` structs.

  Supported inputs:
    * `%Aquila.Message{}`
    * `{role, content}`
    * `%{role: role, content: content}`
    * Maps with string keys (`"role"`, `"content"`)
  """
  @spec coerce(t() | map() | {role(), iodata() | map()}) :: t()
  def coerce(%__MODULE__{} = message), do: message

  def coerce({role, content}) when role in [:system, :user, :assistant, :function] do
    new(role, content)
  end

  def coerce(%{role: role, content: content} = map)
      when role in [:system, :user, :assistant, :function] do
    new(role, content, name: Map.get(map, :name))
  end

  def coerce(%{"role" => role, "content" => content} = map) do
    role_atom = string_role(role)
    new(role_atom, content, name: Map.get(map, "name"))
  end

  def coerce(other) do
    raise ArgumentError, "unsupported message shape: #{inspect(other)}"
  end

  @doc """
  Normalises either a prompt string or a message list into a list of
  `%Aquila.Message{}` structs.

  When given a plain string, either the `:instruction` or `:instructions`
  option is prepended as a system message before the user prompt.
  """
  @spec normalize(iodata() | t() | map() | tuple() | [any()], keyword()) :: [t()]
  def normalize(%__MODULE__{} = message, _opts), do: [message]
  def normalize(list, _opts) when is_list(list), do: Enum.map(list, &coerce/1)

  def normalize(prompt, opts) do
    instruction = opts[:instruction] || opts[:instructions]
    base = if instruction, do: [new(:system, instruction)], else: []
    base ++ [new(:user, prompt)]
  end

  @doc """
  Converts a message into an OpenAI-compatible chat map.
  """
  @spec to_chat_map(t()) :: map()
  def to_chat_map(%__MODULE__{role: role, content: content, name: name}) do
    # Keys are ordered alphabetically to match StableJason sorting
    map = %{content: content, role: Atom.to_string(role)}

    case name do
      nil -> map
      value -> Map.put(map, :name, value)
    end
  end

  @doc false
  @spec function_message(String.t(), iodata()) :: t()
  def function_message(name, content) do
    new(:function, IO.iodata_to_binary(content), name: name)
  end

  defp string_role("system"), do: :system
  defp string_role("user"), do: :user
  defp string_role("assistant"), do: :assistant
  defp string_role("function"), do: :function

  defp string_role(role) do
    raise ArgumentError, "unknown message role #{inspect(role)}"
  end
end
