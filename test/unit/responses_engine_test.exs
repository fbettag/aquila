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

    test "normalizes raw base64 data without data URL prefix" do
      raw_base64 = Base.encode64("hello world")

      message = %Message{
        role: :user,
        content: [
          %{
            type: "file",
            file: %{
              file_data: raw_base64,
              format: "application/json"
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
      assert content_part.file_data == raw_base64
      assert content_part.filename == "document.json"
    end

    test "normalizes atom-keyed image content to input_image" do
      message = %Message{role: :user, content: [%{type: "image", image: %{data: "..."}}]}

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

      assert content_part.type == "input_image"
      assert content_part.image == %{data: "..."}
    end

    test "normalizes string-keyed image_url content to input_image" do
      message = %Message{
        role: :user,
        content: [
          %{
            "type" => "image_url",
            "image_url" => %{"url" => "https://example.com/image.png"}
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

      assert content_part["type"] == "input_image"
      assert content_part["image_url"] == %{"url" => "https://example.com/image.png"}
    end
  end

  describe "build_body/2" do
    defp fetch_key(map, atom_key, string_key) do
      case Map.fetch(map, atom_key) do
        {:ok, value} -> value
        :error -> Map.get(map, string_key)
      end
    end

    defp base_state(overrides) do
      Map.merge(
        %{
          messages: [Message.new(:user, "ping")],
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
        overrides
      )
    end

    test "includes tool payload outputs and flattens tool definitions" do
      tool_def = %{
        "type" => "function",
        "function" => %{
          "name" => "calc",
          "description" => "Adds numbers",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "x" => %{"type" => "number"},
              "y" => %{"type" => "number"}
            },
            "required" => ["x"]
          }
        }
      }

      state =
        base_state(%{
          tool_defs: [tool_def],
          tool_payloads: [%{call_id: "call-1", output: %{"result" => 3}}],
          metadata: %{foo: "bar"},
          store: true,
          instructions: "do math",
          previous_response_id: "prev",
          reasoning: %{effort: "medium"}
        })

      body = Responses.build_body(state, true)

      assert body.stream
      assert body.metadata == %{foo: "bar"}
      assert body.instructions == "do math"
      assert body.previous_response_id == "prev"
      assert body.reasoning == %{effort: "medium"}
      assert body.store == true

      [first_input, second_input] = body.input
      assert first_input.role == "user"
      assert [%{type: "input_text", text: "ping"}] = first_input.content

      assert %{
               type: "function_call_output",
               call_id: "call-1",
               output: %{"result" => 3}
             } = second_input

      [flattened_tool] = body.tools
      type = fetch_key(flattened_tool, :type, "type")
      name = fetch_key(flattened_tool, :name, "name")
      description = fetch_key(flattened_tool, :description, "description")
      parameters = fetch_key(flattened_tool, :parameters, "parameters")
      strict = fetch_key(flattened_tool, :strict, "strict")

      assert type == "function"
      assert name == "calc"
      assert description == "Adds numbers"
      assert parameters["properties"]["x"]
      assert strict == false
    end

    test "omits strict flag when all properties required" do
      tool_def = %{
        "type" => "function",
        "function" => %{
          "name" => "calc",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"x" => %{"type" => "number"}},
            "required" => ["x"]
          }
        }
      }

      body =
        base_state(%{tool_defs: [tool_def], tool_payloads: []})
        |> Responses.build_body(false)

      [tool] = body.tools
      refute Map.has_key?(tool, :strict)
      refute Map.has_key?(tool, "strict")
    end

    test "omits metadata when store disabled" do
      state =
        base_state(%{
          metadata: %{foo: "bar"},
          store: false
        })

      body = Responses.build_body(state, false)
      refute Map.has_key?(body, :metadata)
    end

    test "drops empty metadata map" do
      body =
        base_state(%{
          metadata: %{},
          store: true
        })
        |> Responses.build_body(false)

      refute Map.has_key?(body, :metadata)
    end

    test "treats assistant messages as output text" do
      body =
        base_state(%{messages: [Message.new(:assistant, "done")], store: nil})
        |> Responses.build_body(false)

      [message_input] = body.input
      assert message_input.role == "assistant"
      assert [%{type: "output_text", text: "done"}] = message_input.content
    end

    test "wraps non-map content list as text part" do
      message = %Message{role: :user, content: ["part1", "part2"]}

      body =
        base_state(%{messages: [message]})
        |> Responses.build_body(false)

      [message_input] = body.input
      assert [%{type: "input_text", text: "part1part2"}] = message_input.content
    end

    test "passes through unknown content parts" do
      message = %Message{
        role: :user,
        content: [%{type: "custom", value: 42}]
      }

      body =
        base_state(%{messages: [message]})
        |> Responses.build_body(false)

      [message_input] = body.input
      assert [%{type: "custom", value: 42}] = message_input.content
    end

    test "normalizes string-keyed image content" do
      message = %Message{
        role: :user,
        content: [%{"type" => "image", "image" => %{"data" => "..."}}]
      }

      body =
        base_state(%{messages: [message]})
        |> Responses.build_body(false)

      [message_input] = body.input

      assert [%{"type" => "input_image", "image" => %{"data" => "..."}}] =
               message_input.content
    end

    test "normalizes atom-keyed image_url content" do
      message = %Message{
        role: :user,
        content: [%{type: "image_url", image_url: %{url: "https://example.com/image"}}]
      }

      body =
        base_state(%{messages: [message]})
        |> Responses.build_body(false)

      [message_input] = body.input

      assert [%{type: "input_image", image_url: %{url: "https://example.com/image"}}] =
               message_input.content
    end

    test "function role text parts emit output_text" do
      message = Message.new(:function, "result")

      body =
        base_state(%{messages: [message]})
        |> Responses.build_body(false)

      [message_input] = body.input
      assert message_input.role == "function"
      assert [%{type: "output_text", text: "result"}] = message_input.content
    end
  end
end
