defmodule Aquila.ContentPart do
  @moduledoc """
  Helpers for building structured content parts for multi-modal messages.

  Supports text, images, and file inputs following OpenAI's content format.
  """

  @doc """
  Creates a text content part.

  ## Examples

      iex> Aquila.ContentPart.text("Hello, world!")
      %{type: "text", text: "Hello, world!"}
  """
  @spec text(String.t()) :: map()
  def text(text) when is_binary(text) do
    %{type: "text", text: text}
  end

  @doc """
  Creates an image content part from base64-encoded data.

  ## Options

  * `:media` - The media type (e.g., "image/png", "image/jpeg"). Defaults to "image/png"
  * `:detail` - Level of detail for image analysis. Can be "low", "high", or "auto". Defaults to "auto"

  ## Examples

      iex> Aquila.ContentPart.image(base64_data)
      %{type: "image_url", image_url: %{url: "data:image/png;base64,..."}}

      iex> Aquila.ContentPart.image(base64_data, media: "image/jpeg", detail: "high")
      %{type: "image_url", image_url: %{url: "data:image/jpeg;base64,...", detail: "high"}}
  """
  @spec image(String.t(), keyword()) :: map()
  def image(base64_data, opts \\ []) when is_binary(base64_data) do
    media_type = Keyword.get(opts, :media, "image/png")
    detail = Keyword.get(opts, :detail, "auto")

    image_url = %{url: "data:#{media_type};base64,#{base64_data}"}
    image_url = if detail, do: Map.put(image_url, :detail, detail), else: image_url

    %{type: "image_url", image_url: image_url}
  end

  @doc """
  Creates an image content part from a URL.

  ## Options

  * `:detail` - Level of detail for image analysis. Can be "low", "high", or "auto". Defaults to "auto"

  ## Examples

      iex> Aquila.ContentPart.image_url("https://example.com/image.png")
      %{type: "image_url", image_url: %{url: "https://example.com/image.png", detail: "auto"}}
  """
  @spec image_url(String.t(), keyword()) :: map()
  def image_url(url, opts \\ []) when is_binary(url) do
    detail = Keyword.get(opts, :detail, "auto")

    image_url = %{url: url}
    image_url = if detail, do: Map.put(image_url, :detail, detail), else: image_url

    %{type: "image_url", image_url: image_url}
  end

  @doc """
  Creates a file content part from base64-encoded data.

  Supports PDFs and other file types using LiteLLM proxy format.

  ## Options

  * `:filename` - The name of the file (optional, for reference)
  * `:media` - The media type (e.g., "application/pdf", "text/plain")

  ## Examples

      iex> Aquila.ContentPart.file(base64_data, filename: "document.pdf", media: "application/pdf")
      %{type: "file", file: %{file_data: "data:application/pdf;base64,...", format: "application/pdf"}}

      iex> Aquila.ContentPart.file(base64_data, media: "text/plain")
      %{type: "file", file: %{file_data: "data:text/plain;base64,...", format: "text/plain"}}
  """
  @spec file(String.t(), keyword()) :: map()
  def file(base64_data, opts \\ []) when is_binary(base64_data) do
    media_type = Keyword.get(opts, :media, "application/pdf")

    # Format as data URL with base64
    file_data = "data:#{media_type};base64,#{base64_data}"

    %{
      type: "file",
      file: %{
        file_data: file_data,
        format: media_type
      }
    }
  end

  @doc """
  Creates a file content part from a file ID or URL using LiteLLM proxy format.

  ## Examples

      iex> Aquila.ContentPart.file_id("file-6F2ksmvXxt4VdoqmHRw6kL")
      %{type: "file", file: %{file_id: "file-6F2ksmvXxt4VdoqmHRw6kL"}}

      iex> Aquila.ContentPart.file_id("https://example.com/document.pdf", "application/pdf")
      %{type: "file", file: %{file_id: "https://example.com/document.pdf", format: "application/pdf"}}
  """
  @spec file_id(String.t(), String.t() | nil) :: map()
  def file_id(file_id, format \\ nil) when is_binary(file_id) do
    file_obj = %{file_id: file_id}
    file_obj = if format, do: Map.put(file_obj, :format, format), else: file_obj

    %{type: "file", file: file_obj}
  end

  @doc """
  Creates a file content part from a URL using LiteLLM proxy format.

  ## Examples

      iex> Aquila.ContentPart.file_url("https://example.com/document.pdf")
      %{type: "file", file: %{file_id: "https://example.com/document.pdf", format: "application/pdf"}}

      iex> Aquila.ContentPart.file_url("https://example.com/report.txt", "text/plain")
      %{type: "file", file: %{file_id: "https://example.com/report.txt", format: "text/plain"}}
  """
  @spec file_url(String.t(), String.t() | nil) :: map()
  def file_url(url, format \\ nil) when is_binary(url) do
    # Infer format from URL if not provided
    inferred_format =
      if format do
        format
      else
        url
        |> URI.parse()
        |> Map.get(:path, "")
        |> Path.extname()
        |> case do
          ".pdf" -> "application/pdf"
          ".txt" -> "text/plain"
          ".doc" -> "application/msword"
          ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
          _ -> "application/octet-stream"
        end
      end

    file_id(url, inferred_format)
  end

  @doc """
  Detects content type and creates appropriate content part.

  Useful for dynamically handling different content types.

  ## Examples

      iex> Aquila.ContentPart.auto("Hello")
      %{type: "input_text", text: "Hello"}

      iex> Aquila.ContentPart.auto(base64_data, type: :image, media: "image/jpeg")
      %{type: "image_url", image_url: %{url: "data:image/jpeg;base64,..."}}
  """
  @spec auto(String.t(), keyword()) :: map()
  def auto(content, opts \\ [])

  def auto(content, opts) when is_binary(content) do
    case Keyword.get(opts, :type) do
      :text -> text(content)
      :image -> image(content, opts)
      :file -> file(content, opts)
      # Default to text
      nil -> text(content)
      other -> raise ArgumentError, "unknown content type: #{inspect(other)}"
    end
  end
end
