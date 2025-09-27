defmodule Aquila.Assistant do
  @moduledoc """
  Struct representing an AI assistant configuration.

  An assistant encapsulates the configuration for an AI interaction, including:
  - System instructions (personality, behavior, constraints)
  - Available tools/functions
  - Model selection
  - Temperature and other parameters
  - Context/history

  ## Fields

  - `:instructions` - System prompt defining assistant behavior
  - `:tools` - List of available tools (`Aquila.Tool.t()`)
  - `:model` - Model identifier (e.g., "gpt-4o", "gpt-4o-mini")
  - `:temperature` - Sampling temperature (0.0-2.0)
  - `:context` - Previous conversation context or history

  ## Examples

      assistant = Aquila.Assistant.new(
        model: "gpt-4o-mini",
        tools: [calculator_tool],
        context: previous_messages
      )

      assistant = Aquila.Assistant.new(model: "gpt-4o")
      |> Aquila.Assistant.with_system("You are a helpful coding assistant.")
  """

  @enforce_keys []
  defstruct [
    :instructions,
    :tools,
    :model,
    :temperature,
    :context,
    :messages
  ]

  @type t :: %__MODULE__{
          instructions: String.t() | nil,
          tools: [Aquila.Tool.t()] | nil,
          model: String.t() | nil,
          temperature: float() | nil,
          context: term() | nil,
          messages: [map()] | nil
        }

  @doc """
  Creates a new assistant struct from options.

  ## Options

  - `:instructions` or `:system` - System prompt
  - `:tools` - List of tools
  - `:model` - Model name
  - `:temperature` - Sampling temperature
  - `:context` - Conversation context

  ## Examples

      Aquila.Assistant.new(model: "gpt-4o-mini")
      Aquila.Assistant.new(model: "gpt-4o", tools: [my_tool])
  """
  def new(opts \\ []) when is_list(opts) do
    instructions = Keyword.get(opts, :instructions) || Keyword.get(opts, :system)

    %__MODULE__{
      instructions: instructions,
      tools: Keyword.get(opts, :tools),
      model: Keyword.get(opts, :model),
      temperature: Keyword.get(opts, :temperature),
      context: Keyword.get(opts, :context),
      messages: Keyword.get(opts, :messages)
    }
  end

  @doc """
  Sets or updates the system instructions.

  ## Examples

      assistant
      |> Aquila.Assistant.with_system("You are a helpful assistant.")
  """
  def with_system(%__MODULE__{} = assistant, instructions) when is_binary(instructions) do
    %{assistant | instructions: instructions}
  end

  @doc """
  Adds tools to the assistant.

  ## Examples

      assistant
      |> Aquila.Assistant.with_tools([calculator, weather])
  """
  def with_tools(%__MODULE__{} = assistant, tools) when is_list(tools) do
    %{assistant | tools: tools}
  end

  @doc """
  Sets the model.

  ## Examples

      assistant
      |> Aquila.Assistant.with_model("gpt-4o")
  """
  def with_model(%__MODULE__{} = assistant, model) when is_binary(model) do
    %{assistant | model: model}
  end

  @doc """
  Sets the temperature.

  ## Examples

      assistant
      |> Aquila.Assistant.with_temperature(0.7)
  """
  def with_temperature(%__MODULE__{} = assistant, temperature) when is_float(temperature) do
    %{assistant | temperature: temperature}
  end

  @doc """
  Sets the context.

  ## Examples

      assistant
      |> Aquila.Assistant.with_context(previous_messages)
  """
  def with_context(%__MODULE__{} = assistant, context) do
    %{assistant | context: context}
  end

  @doc """
  Sets the messages.

  ## Examples

      assistant
      |> Aquila.Assistant.with_messages(messages)
  """
  def with_messages(%__MODULE__{} = assistant, messages) when is_list(messages) do
    %{assistant | messages: messages}
  end
end
