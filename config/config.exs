import Config

config :aquila,
  recorder: [
    path: "test/support/fixtures/aquila_cassettes",
    transport: Aquila.Transport.OpenAI
  ]

config :aquila, :openai,
  base_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
  api_key: System.get_env("OPENAI_API_KEY"),
  default_model: "gpt-4o-mini",
  transcription_model: "gpt-4o-mini-transcribe",
  request_timeout: 30_000

import_config "#{config_env()}.exs"
