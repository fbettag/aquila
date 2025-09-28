import Config

config :aquila,
  recorder: [
    path: "test/support/fixtures/aquila_cassettes",
    transport: Aquila.Transport.OpenAI
  ]

config :aquila, :openai,
  base_url: "https://api.openai.com/v1",
  default_model: "gpt-4o-mini",
  transcription_model: "gpt-4o-mini-transcribe",
  api_key: {:system, "OPENAI_API_KEY"},
  request_timeout: 30_000

import_config "#{config_env()}.exs"
