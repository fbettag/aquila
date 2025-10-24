defmodule Aquila.ResponsesEngineTest do
  use ExUnit.Case, async: true

  alias Aquila.Engine.Responses
  alias Aquila.Message

  describe "file content normalization" do
    test "normalizes file with data URL to input_file format (atom keys)" do
      base64 = "JVBERi0xLjQK"
      data_url = "data:application/pdf;base64,#{base64}"

      message = %Message{
        role: :user,
        content: [
          %{
            type: "file",
            file: %{
              file_data: data_url,
              format: "application/pdf",
              filename: "document.pdf"
            }
          }
        ]
      }

      result =
        Responses.build_body(
          %{
            messages: [message],
            model: "gpt-4",
            tool_defs: [],
            tool_payloads: [],
            metadata: nil,
            store: nil,
            instructions: nil,
            response_id: nil,
            previous_response_id: nil,
            reasoning: nil
          },
          false
        )

      [input_message] = result.input
      [content_part] = input_message.content

      assert content_part.type == "input_file"
      assert content_part.file_data == data_url
      assert content_part.filename == "document.pdf"
      refute Map.has_key?(content_part, :file)
    end

    test "normalizes file with data URL to input_file format (string keys)" do
      base64 = "JVBERi0xLjQK"
      data_url = "data:application/pdf;base64,#{base64}"

      message = %Message{
        role: :user,
        content: [
          %{
            "type" => "file",
            "file" => %{
              "file_data" => data_url,
              "format" => "application/pdf",
              "filename" => "document.pdf"
            }
          }
        ]
      }

      result =
        Responses.build_body(
          %{
            messages: [message],
            model: "gpt-4",
            tool_defs: [],
            tool_payloads: [],
            metadata: nil,
            store: nil,
            instructions: nil,
            response_id: nil,
            previous_response_id: nil,
            reasoning: nil
          },
          false
        )

      [input_message] = result.input
      [content_part] = input_message.content

      assert content_part["type"] == "input_file"
      assert content_part["file_data"] == data_url
      assert content_part["filename"] == "document.pdf"
      refute Map.has_key?(content_part, "file")
    end

    test "preserves data URL format for file_data (does not strip prefix)" do
      base64 = "SGVsbG8gd29ybGQ="
      data_url = "data:text/plain;base64,#{base64}"

      message = %Message{
        role: :user,
        content: [
          %{
            type: "file",
            file: %{
              file_data: data_url,
              format: "text/plain",
              filename: "data.txt"
            }
          }
        ]
      }

      result =
        Responses.build_body(
          %{
            messages: [message],
            model: "gpt-4",
            tool_defs: [],
            tool_payloads: [],
            metadata: nil,
            store: nil,
            instructions: nil,
            response_id: nil,
            previous_response_id: nil,
            reasoning: nil
          },
          false
        )

      [input_message] = result.input
      [content_part] = input_message.content

      # Verify the full data URL is preserved
      assert content_part.file_data == data_url
      assert String.starts_with?(content_part.file_data, "data:text/plain;base64,")
    end

    test "normalizes file URL to input_file with file_url" do
      url = "https://example.com/document.pdf"

      message = %Message{
        role: :user,
        content: [
          %{
            type: "file",
            file: %{
              file_data: url,
              format: "application/pdf",
              filename: "document.pdf"
            }
          }
        ]
      }

      result =
        Responses.build_body(
          %{
            messages: [message],
            model: "gpt-4",
            tool_defs: [],
            tool_payloads: [],
            metadata: nil,
            store: nil,
            instructions: nil,
            response_id: nil,
            previous_response_id: nil,
            reasoning: nil
          },
          false
        )

      [input_message] = result.input
      [content_part] = input_message.content

      assert content_part.type == "input_file"
      assert content_part.file_url == url
      refute Map.has_key?(content_part, :file_data)
      refute Map.has_key?(content_part, :file)
    end

    test "infers filename when not provided" do
      base64 = "JVBERi0xLjQK"
      data_url = "data:application/pdf;base64,#{base64}"

      message = %Message{
        role: :user,
        content: [
          %{
            type: "file",
            file: %{
              file_data: data_url,
              format: "application/pdf"
            }
          }
        ]
      }

      result =
        Responses.build_body(
          %{
            messages: [message],
            model: "gpt-4",
            tool_defs: [],
            tool_payloads: [],
            metadata: nil,
            store: nil,
            instructions: nil,
            response_id: nil,
            previous_response_id: nil,
            reasoning: nil
          },
          false
        )

      [input_message] = result.input
      [content_part] = input_message.content

      assert content_part.type == "input_file"
      # Should infer filename from format
      assert content_part.filename == "document.pdf"
    end

    test "handles file with URL as file_data" do
      url = "https://cdn.example.com/files/document.pdf"

      message = %Message{
        role: :user,
        content: [
          %{
            type: "file",
            file: %{
              file_data: url,
              format: "application/pdf",
              filename: "document.pdf"
            }
          }
        ]
      }

      result =
        Responses.build_body(
          %{
            messages: [message],
            model: "gpt-4",
            tool_defs: [],
            tool_payloads: [],
            metadata: nil,
            store: nil,
            instructions: nil,
            response_id: nil,
            previous_response_id: nil,
            reasoning: nil
          },
          false
        )

      [input_message] = result.input
      [content_part] = input_message.content

      assert content_part.type == "input_file"
      # URL gets converted to file_url
      assert content_part.file_url == url
      refute Map.has_key?(content_part, :file_data)
    end

    test "handles multiple content parts including files" do
      base64 = "JVBERi0xLjQK"
      data_url = "data:application/pdf;base64,#{base64}"

      message = %Message{
        role: :user,
        content: [
          %{type: "text", text: "Please review this document:"},
          %{
            type: "file",
            file: %{
              file_data: data_url,
              format: "application/pdf",
              filename: "report.pdf"
            }
          }
        ]
      }

      result =
        Responses.build_body(
          %{
            messages: [message],
            model: "gpt-4",
            tool_defs: [],
            tool_payloads: [],
            metadata: nil,
            store: nil,
            instructions: nil,
            response_id: nil,
            previous_response_id: nil,
            reasoning: nil
          },
          false
        )

      [input_message] = result.input
      [text_part, file_part] = input_message.content

      assert text_part.type == "input_text"
      assert text_part.text == "Please review this document:"

      assert file_part.type == "input_file"
      assert file_part.file_data == data_url
      assert file_part.filename == "report.pdf"
    end
  end
end
