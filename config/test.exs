import Config

config :aquila,
  transport: Aquila.Transport.Record,
  recorder: [
    path: "test/support/fixtures/aquila_cassettes",
    transport: Aquila.Transport.OpenAI
  ]

config :aquila, :openai,
  base_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1"),
  api_key: System.get_env("OPENAI_API_KEY"),
  default_model: System.get_env("TEST_MODEL", "gpt-4o-mini"),
  transcription_model: "gpt-4o-mini-transcribe",
  request_timeout: 30_000

# Print only warnings and errors during test
config :logger, level: :error

# Suppress SASL reports (Task crashes, supervisor errors) during tests
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  handle_otp_reports: false,
  handle_sasl_reports: false
