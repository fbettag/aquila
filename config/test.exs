import Config

config :aquila,
  transport: Aquila.Transport.Record,
  recorder: [
    path: "test/support/fixtures/aquila_cassettes",
    transport: Aquila.Transport.OpenAI
  ]

config :aquila, :openai,
  base_url: "https://api.openai.com/v1",
  api_key: {:system, "OPENAI_API_KEY"},
  default_model: "gpt-4o-mini",
  transcription_model: "gpt-4o-mini-transcribe",
  request_timeout: 30_000
