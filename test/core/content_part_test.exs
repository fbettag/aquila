defmodule Aquila.ContentPartTest do
  use ExUnit.Case, async: true

  alias Aquila.ContentPart

  describe "text/1" do
    test "creates text content part" do
      assert %{type: "text", text: "Hello, world!"} = ContentPart.text("Hello, world!")
    end

    test "handles empty strings" do
      assert %{type: "text", text: ""} = ContentPart.text("")
    end
  end

  describe "image/2" do
    test "creates image content part with base64 data and defaults" do
      base64 = "iVBORw0KGgoAAAANSUhEUg=="
      result = ContentPart.image(base64)

      assert result.type == "image_url"
      assert result.image_url.url == "data:image/png;base64,#{base64}"
      assert result.image_url.detail == "auto"
    end

    test "accepts custom media type" do
      base64 = "iVBORw0KGgoAAAANSUhEUg=="
      result = ContentPart.image(base64, media: "image/jpeg")

      assert result.image_url.url == "data:image/jpeg;base64,#{base64}"
    end

    test "accepts custom detail level" do
      base64 = "iVBORw0KGgoAAAANSUhEUg=="
      result = ContentPart.image(base64, detail: "high")

      assert result.image_url.detail == "high"
    end

    test "accepts both media and detail options" do
      base64 = "iVBORw0KGgoAAAANSUhEUg=="
      result = ContentPart.image(base64, media: "image/jpeg", detail: "low")

      assert result.image_url.url == "data:image/jpeg;base64,#{base64}"
      assert result.image_url.detail == "low"
    end
  end

  describe "image_url/2" do
    test "creates image content part from URL with defaults" do
      url = "https://example.com/image.png"
      result = ContentPart.image_url(url)

      assert result.type == "image_url"
      assert result.image_url.url == url
      assert result.image_url.detail == "auto"
    end

    test "accepts custom detail level" do
      url = "https://example.com/image.png"
      result = ContentPart.image_url(url, detail: "high")

      assert result.image_url.detail == "high"
    end

    test "accepts nil detail level" do
      url = "https://example.com/image.png"
      result = ContentPart.image_url(url, detail: nil)

      refute Map.has_key?(result.image_url, :detail)
    end
  end

  describe "file/2" do
    test "creates file content part with base64 data and defaults" do
      base64 = "JVBERi0xLjQK"
      result = ContentPart.file(base64)

      assert result.type == "file"
      assert result.file.file_data == "data:application/pdf;base64,#{base64}"
      assert result.file.format == "application/pdf"
    end

    test "accepts custom media type" do
      base64 = "SGVsbG8gd29ybGQ="
      result = ContentPart.file(base64, media: "text/plain")

      assert result.file.file_data == "data:text/plain;base64,#{base64}"
      assert result.file.format == "text/plain"
    end

    test "accepts filename option" do
      base64 = "JVBERi0xLjQK"
      result = ContentPart.file(base64, filename: "document.pdf", media: "application/pdf")

      assert result.file.file_data == "data:application/pdf;base64,#{base64}"
      assert result.file.format == "application/pdf"
    end
  end

  describe "file_id/2" do
    test "creates file content part from file ID" do
      file_id = "file-6F2ksmvXxt4VdoqmHRw6kL"
      result = ContentPart.file_id(file_id)

      assert result.type == "file"
      assert result.file.file_id == file_id
      refute Map.has_key?(result.file, :format)
    end

    test "accepts format parameter" do
      file_id = "file-6F2ksmvXxt4VdoqmHRw6kL"
      result = ContentPart.file_id(file_id, "application/pdf")

      assert result.file.file_id == file_id
      assert result.file.format == "application/pdf"
    end

    test "accepts nil format" do
      file_id = "file-6F2ksmvXxt4VdoqmHRw6kL"
      result = ContentPart.file_id(file_id, nil)

      assert result.file.file_id == file_id
      refute Map.has_key?(result.file, :format)
    end

    test "works with URL as file_id" do
      url = "https://example.com/document.pdf"
      result = ContentPart.file_id(url, "application/pdf")

      assert result.file.file_id == url
      assert result.file.format == "application/pdf"
    end
  end

  describe "file_url/2" do
    test "creates file content part from URL and infers PDF format" do
      url = "https://example.com/document.pdf"
      result = ContentPart.file_url(url)

      assert result.type == "file"
      assert result.file.file_id == url
      assert result.file.format == "application/pdf"
    end

    test "infers text/plain format from .txt extension" do
      url = "https://example.com/report.txt"
      result = ContentPart.file_url(url)

      assert result.file.format == "text/plain"
    end

    test "infers application/msword from .doc extension" do
      url = "https://example.com/document.doc"
      result = ContentPart.file_url(url)

      assert result.file.format == "application/msword"
    end

    test "infers docx format from .docx extension" do
      url = "https://example.com/document.docx"
      result = ContentPart.file_url(url)

      assert result.file.format ==
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    end

    test "defaults to application/octet-stream for unknown extensions" do
      url = "https://example.com/file.xyz"
      result = ContentPart.file_url(url)

      assert result.file.format == "application/octet-stream"
    end

    test "accepts explicit format parameter" do
      url = "https://example.com/document.pdf"
      result = ContentPart.file_url(url, "application/custom")

      assert result.file.format == "application/custom"
    end

    test "handles URLs without extensions" do
      url = "https://example.com/document"
      result = ContentPart.file_url(url)

      assert result.file.format == "application/octet-stream"
    end
  end

  describe "auto/2" do
    test "defaults to text content" do
      result = ContentPart.auto("Hello")

      assert result.type == "text"
      assert result.text == "Hello"
    end

    test "creates text content when type is :text" do
      result = ContentPart.auto("Hello", type: :text)

      assert result.type == "text"
      assert result.text == "Hello"
    end

    test "creates image content when type is :image" do
      base64 = "iVBORw0KGgoAAAANSUhEUg=="
      result = ContentPart.auto(base64, type: :image)

      assert result.type == "image_url"
      assert result.image_url.url == "data:image/png;base64,#{base64}"
    end

    test "creates image content with options" do
      base64 = "iVBORw0KGgoAAAANSUhEUg=="
      result = ContentPart.auto(base64, type: :image, media: "image/jpeg", detail: "high")

      assert result.image_url.url == "data:image/jpeg;base64,#{base64}"
      assert result.image_url.detail == "high"
    end

    test "creates file content when type is :file" do
      base64 = "JVBERi0xLjQK"
      result = ContentPart.auto(base64, type: :file)

      assert result.type == "file"
      assert result.file.file_data == "data:application/pdf;base64,#{base64}"
    end

    test "creates file content with options" do
      base64 = "SGVsbG8gd29ybGQ="
      result = ContentPart.auto(base64, type: :file, media: "text/plain")

      assert result.file.file_data == "data:text/plain;base64,#{base64}"
      assert result.file.format == "text/plain"
    end

    test "raises for unknown content type" do
      assert_raise ArgumentError, ~r/unknown content type: :unknown/, fn ->
        ContentPart.auto("data", type: :unknown)
      end
    end
  end
end
