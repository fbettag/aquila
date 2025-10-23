defmodule Aquila.Message do
  @moduledoc """
  Chat-style message structure shared across transports.

  Provides helpers for coercing user input into normalised
  `%Aquila.Message{}` structs so that `Aquila.Engine` can operate on consistent data
  regardless of the upstream endpoint or prompt shape.
  """

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :name, :tool_call_id, :tool_calls]

  @type role :: :system | :user | :assistant | :function | :tool
  @type t :: %__MODULE__{
          role: role(),
          content: iodata() | map(),
          name: nil | String.t(),
          tool_call_id: nil | String.t(),
          tool_calls: nil | list()
        }

  @doc """
  Builds a new message.

  ## Options

  * `:name` – assistant/function name associated with the message.
  * `:tool_call_id` – tool call ID for tool role messages (required for newer models like GPT-5).
  """
  @spec new(role(), iodata() | map(), keyword()) :: t()
  def new(role, content, opts \\ [])
      when role in [:system, :user, :assistant, :function, :tool] do
    struct!(__MODULE__,
      role: role,
      content: content,
      name: Keyword.get(opts, :name),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      tool_calls: Keyword.get(opts, :tool_calls)
    )
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

  def coerce({role, content}) when role in [:system, :user, :assistant, :function, :tool] do
    new(role, content)
  end

  def coerce(%{role: role, content: content} = map)
      when role in [:system, :user, :assistant, :function, :tool] do
    new(role, content,
      name: Map.get(map, :name),
      tool_call_id: Map.get(map, :tool_call_id),
      tool_calls: Map.get(map, :tool_calls)
    )
  end

  def coerce(%{"role" => role, "content" => content} = map) do
    role_atom = string_role(role)

    new(role_atom, content,
      name: Map.get(map, "name"),
      tool_call_id: Map.get(map, "tool_call_id"),
      tool_calls: Map.get(map, "tool_calls")
    )
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
  def to_chat_map(%__MODULE__{
        role: role,
        content: content,
        name: name,
        tool_call_id: tool_call_id,
        tool_calls: tool_calls
      }) do
    # Keys are ordered alphabetically to match StableJason sorting
    map = %{content: content, role: Atom.to_string(role)}

    map =
      case name do
        nil -> map
        value -> Map.put(map, :name, value)
      end

    map =
      case tool_call_id do
        nil -> map
        value -> Map.put(map, :tool_call_id, value)
      end

    case tool_calls do
      nil -> map
      value -> Map.put(map, :tool_calls, value)
    end
  end

  @doc false
  @spec function_message(String.t(), iodata(), keyword()) :: t()
  def function_message(name, content, opts \\ []) do
    # For backward compatibility, this creates function role messages by default.
    # Use tool_output_message/3 for the newer tool role format.
    new(:function, IO.iodata_to_binary(content), Keyword.merge([name: name], opts))
  end

  @doc false
  @spec tool_output_message(String.t(), iodata(), keyword()) :: t()
  def tool_output_message(name, content, opts) do
    # Creates a tool output message for newer models (GPT-5+).
    # Requires :tool_call_id option for the tool role.
    tool_call_id = Keyword.fetch!(opts, :tool_call_id)
    text = IO.iodata_to_binary(content)

    case Keyword.get(opts, :format, :text) do
      :tool_result ->
        message_content = [
          %{
            "type" => "tool_result",
            "tool_use_id" => tool_call_id,
            "content" => [
              %{"type" => "output_text", "text" => text}
            ]
          }
        ]

        new(:tool, message_content, name: name, tool_call_id: tool_call_id)

      :text ->
        new(:tool, text, name: name, tool_call_id: tool_call_id)
    end
  end

  @doc """
  Converts a list of messages to serializable map format.

  This is useful for maintaining conversation history across multiple turns,
  especially when tools are involved. The returned list can be passed to
  subsequent `Aquila.ask/2` calls.

  ## Examples

      iex> messages = [
      ...>   Message.new(:user, "Hello"),
      ...>   Message.new(:assistant, "Hi there!")
      ...> ]
      iex> Message.to_list(messages)
      [
        %{role: :user, content: "Hello"},
        %{role: :assistant, content: "Hi there!"}
      ]
  """
  @spec to_list([t()]) :: [map()]
  def to_list(messages) when is_list(messages) do
    Enum.map(messages, &to_map/1)
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = message) do
    base = %{
      role: message.role,
      content: normalize_content_for_serialization(message.content)
    }

    base
    |> maybe_put_field(:name, message.name)
    |> maybe_put_field(:tool_call_id, message.tool_call_id)
    |> maybe_put_field(:tool_calls, message.tool_calls)
  end

  defp normalize_content_for_serialization(content) when is_binary(content), do: content
  defp normalize_content_for_serialization(content) when is_list(content), do: content
  defp normalize_content_for_serialization(content) when is_map(content), do: content

  defp normalize_content_for_serialization(content) do
    # For iodata that's not a simple binary/list/map, convert to binary
    IO.iodata_to_binary(content)
  rescue
    _ -> inspect(content)
  end

  defp maybe_put_field(map, _key, nil), do: map
  defp maybe_put_field(map, key, value), do: Map.put(map, key, value)

  defp string_role("system"), do: :system
  defp string_role("user"), do: :user
  defp string_role("assistant"), do: :assistant
  defp string_role("function"), do: :function
  defp string_role("tool"), do: :tool

  defp string_role(role) do
    raise ArgumentError, "unknown message role #{inspect(role)}"
  end
end
