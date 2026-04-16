# Top 33 models by popularity
# Run with: mix run priv/repo/seeds/models.exs

alias DodoRouter.Models

models = [
  # OpenAI - GPT-4 family
  %{
    provider_slug: "openai",
    model_id: "gpt-4o",
    display_name: "GPT-4o",
    max_input_tokens: 128_000,
    max_output_tokens: 16_384,
    input_price_per_million: Decimal.new("2.50"),
    output_price_per_million: Decimal.new("10.00"),
    supports_vision: true,
    supports_audio_input: true,
    supports_function_calling: true,
    supports_response_schema: true,
    supports_prompt_caching: true
  },
  %{
    provider_slug: "openai",
    model_id: "gpt-4o-mini",
    display_name: "GPT-4o Mini",
    max_input_tokens: 128_000,
    max_output_tokens: 16_384,
    input_price_per_million: Decimal.new("0.15"),
    output_price_per_million: Decimal.new("0.60"),
    supports_vision: true,
    supports_function_calling: true,
    supports_response_schema: true
  },
  %{
    provider_slug: "openai",
    model_id: "gpt-4-turbo",
    display_name: "GPT-4 Turbo",
    max_input_tokens: 128_000,
    max_output_tokens: 4_096,
    input_price_per_million: Decimal.new("10.00"),
    output_price_per_million: Decimal.new("30.00"),
    supports_vision: true,
    supports_function_calling: true
  },
  %{
    provider_slug: "openai",
    model_id: "gpt-4.1",
    display_name: "GPT-4.1",
    max_input_tokens: 1_000_000,
    max_output_tokens: 32_768,
    input_price_per_million: Decimal.new("2.00"),
    output_price_per_million: Decimal.new("8.00"),
    supports_vision: true,
    supports_audio_input: true,
    supports_function_calling: true,
    supports_response_schema: true,
    supports_prompt_caching: true
  },
  %{
    provider_slug: "openai",
    model_id: "gpt-4.1-mini",
    display_name: "GPT-4.1 Mini",
    max_input_tokens: 1_000_000,
    max_output_tokens: 32_768,
    input_price_per_million: Decimal.new("0.40"),
    output_price_per_million: Decimal.new("1.60"),
    supports_vision: true,
    supports_function_calling: true,
    supports_response_schema: true
  },
  %{
    provider_slug: "openai",
    model_id: "o1",
    display_name: "o1",
    max_input_tokens: 200_000,
    max_output_tokens: 100_000,
    input_price_per_million: Decimal.new("15.00"),
    output_price_per_million: Decimal.new("60.00"),
    supports_vision: true,
    supports_function_calling: true,
    supports_reasoning: true
  },
  %{
    provider_slug: "openai",
    model_id: "o1-mini",
    display_name: "o1 Mini",
    max_input_tokens: 128_000,
    max_output_tokens: 65_536,
    input_price_per_million: Decimal.new("3.00"),
    output_price_per_million: Decimal.new("12.00"),
    supports_reasoning: true
  },
  %{
    provider_slug: "openai",
    model_id: "o3",
    display_name: "o3",
    max_input_tokens: 200_000,
    max_output_tokens: 100_000,
    input_price_per_million: Decimal.new("10.00"),
    output_price_per_million: Decimal.new("40.00"),
    supports_vision: true,
    supports_function_calling: true,
    supports_reasoning: true,
    supports_response_schema: true
  },
  %{
    provider_slug: "openai",
    model_id: "o3-mini",
    display_name: "o3 Mini",
    max_input_tokens: 200_000,
    max_output_tokens: 100_000,
    input_price_per_million: Decimal.new("1.10"),
    output_price_per_million: Decimal.new("4.40"),
    supports_function_calling: true,
    supports_reasoning: true
  },

  # Anthropic - Claude family
  %{
    provider_slug: "anthropic",
    model_id: "claude-sonnet-4-20250514",
    display_name: "Claude Sonnet 4",
    max_input_tokens: 200_000,
    max_output_tokens: 64_000,
    input_price_per_million: Decimal.new("3.00"),
    output_price_per_million: Decimal.new("15.00"),
    supports_vision: true,
    supports_function_calling: true,
    supports_prompt_caching: true,
    supports_response_schema: true
  },
  %{
    provider_slug: "anthropic",
    model_id: "claude-opus-4-20250514",
    display_name: "Claude Opus 4",
    max_input_tokens: 200_000,
    max_output_tokens: 32_000,
    input_price_per_million: Decimal.new("15.00"),
    output_price_per_million: Decimal.new("75.00"),
    supports_vision: true,
    supports_function_calling: true,
    supports_prompt_caching: true,
    supports_reasoning: true
  },
  %{
    provider_slug: "anthropic",
    model_id: "claude-3-5-sonnet-20241022",
    display_name: "Claude 3.5 Sonnet",
    max_input_tokens: 200_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("3.00"),
    output_price_per_million: Decimal.new("15.00"),
    supports_vision: true,
    supports_function_calling: true,
    supports_prompt_caching: true
  },
  %{
    provider_slug: "anthropic",
    model_id: "claude-3-5-haiku-20241022",
    display_name: "Claude 3.5 Haiku",
    max_input_tokens: 200_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.80"),
    output_price_per_million: Decimal.new("4.00"),
    supports_vision: true,
    supports_function_calling: true,
    supports_prompt_caching: true
  },
  %{
    provider_slug: "anthropic",
    model_id: "claude-3-opus-20240229",
    display_name: "Claude 3 Opus",
    max_input_tokens: 200_000,
    max_output_tokens: 4_096,
    input_price_per_million: Decimal.new("15.00"),
    output_price_per_million: Decimal.new("75.00"),
    supports_vision: true,
    supports_function_calling: true
  },

  # Google - Gemini family
  %{
    provider_slug: "google",
    model_id: "gemini-2.0-flash",
    display_name: "Gemini 2.0 Flash",
    max_input_tokens: 1_000_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.10"),
    output_price_per_million: Decimal.new("0.40"),
    supports_vision: true,
    supports_audio_input: true,
    supports_function_calling: true,
    supports_response_schema: true
  },
  %{
    provider_slug: "google",
    model_id: "gemini-2.5-pro",
    display_name: "Gemini 2.5 Pro",
    max_input_tokens: 1_000_000,
    max_output_tokens: 65_536,
    input_price_per_million: Decimal.new("1.25"),
    output_price_per_million: Decimal.new("10.00"),
    supports_vision: true,
    supports_audio_input: true,
    supports_function_calling: true,
    supports_response_schema: true,
    supports_reasoning: true
  },
  %{
    provider_slug: "google",
    model_id: "gemini-2.5-flash",
    display_name: "Gemini 2.5 Flash",
    max_input_tokens: 1_000_000,
    max_output_tokens: 65_536,
    input_price_per_million: Decimal.new("0.15"),
    output_price_per_million: Decimal.new("0.60"),
    supports_vision: true,
    supports_audio_input: true,
    supports_function_calling: true,
    supports_response_schema: true,
    supports_reasoning: true
  },
  %{
    provider_slug: "google",
    model_id: "gemini-1.5-pro",
    display_name: "Gemini 1.5 Pro",
    max_input_tokens: 2_000_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("1.25"),
    output_price_per_million: Decimal.new("5.00"),
    supports_vision: true,
    supports_audio_input: true,
    supports_function_calling: true
  },
  %{
    provider_slug: "google",
    model_id: "gemini-1.5-flash",
    display_name: "Gemini 1.5 Flash",
    max_input_tokens: 1_000_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.075"),
    output_price_per_million: Decimal.new("0.30"),
    supports_vision: true,
    supports_audio_input: true,
    supports_function_calling: true
  },

  # Meta - Llama family (via Groq/Together)
  %{
    provider_slug: "groq",
    model_id: "llama-3.3-70b-versatile",
    display_name: "Llama 3.3 70B",
    max_input_tokens: 128_000,
    max_output_tokens: 32_768,
    input_price_per_million: Decimal.new("0.59"),
    output_price_per_million: Decimal.new("0.79"),
    supports_function_calling: true
  },
  %{
    provider_slug: "groq",
    model_id: "llama-3.1-8b-instant",
    display_name: "Llama 3.1 8B",
    max_input_tokens: 128_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.05"),
    output_price_per_million: Decimal.new("0.08"),
    supports_function_calling: true
  },
  %{
    provider_slug: "groq",
    model_id: "llama-4-scout-17b-16e-instruct",
    display_name: "Llama 4 Scout 17B",
    max_input_tokens: 128_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.11"),
    output_price_per_million: Decimal.new("0.34"),
    supports_vision: true,
    supports_function_calling: true
  },
  %{
    provider_slug: "groq",
    model_id: "llama-4-maverick-17b-128e-instruct",
    display_name: "Llama 4 Maverick 17B",
    max_input_tokens: 128_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.20"),
    output_price_per_million: Decimal.new("0.60"),
    supports_vision: true,
    supports_function_calling: true
  },

  # Mistral
  %{
    provider_slug: "mistral",
    model_id: "mistral-large-latest",
    display_name: "Mistral Large",
    max_input_tokens: 128_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("2.00"),
    output_price_per_million: Decimal.new("6.00"),
    supports_function_calling: true,
    supports_response_schema: true
  },
  %{
    provider_slug: "mistral",
    model_id: "mistral-small-latest",
    display_name: "Mistral Small",
    max_input_tokens: 32_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.20"),
    output_price_per_million: Decimal.new("0.60"),
    supports_function_calling: true
  },
  %{
    provider_slug: "mistral",
    model_id: "codestral-latest",
    display_name: "Codestral",
    max_input_tokens: 32_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.30"),
    output_price_per_million: Decimal.new("0.90"),
    supports_function_calling: true
  },

  # xAI - Grok
  %{
    provider_slug: "xai",
    model_id: "grok-3",
    display_name: "Grok 3",
    max_input_tokens: 131_072,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("3.00"),
    output_price_per_million: Decimal.new("15.00"),
    supports_vision: true,
    supports_function_calling: true
  },
  %{
    provider_slug: "xai",
    model_id: "grok-3-mini",
    display_name: "Grok 3 Mini",
    max_input_tokens: 131_072,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.30"),
    output_price_per_million: Decimal.new("0.50"),
    supports_function_calling: true
  },

  # DeepSeek
  %{
    provider_slug: "deepseek",
    model_id: "deepseek-chat",
    display_name: "DeepSeek V3",
    max_input_tokens: 64_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.27"),
    output_price_per_million: Decimal.new("1.10"),
    supports_function_calling: true
  },
  %{
    provider_slug: "deepseek",
    model_id: "deepseek-reasoner",
    display_name: "DeepSeek R1",
    max_input_tokens: 64_000,
    max_output_tokens: 8_192,
    input_price_per_million: Decimal.new("0.55"),
    output_price_per_million: Decimal.new("2.19"),
    supports_reasoning: true
  },

  # Cohere
  %{
    provider_slug: "cohere",
    model_id: "command-r-plus",
    display_name: "Command R+",
    max_input_tokens: 128_000,
    max_output_tokens: 4_096,
    input_price_per_million: Decimal.new("2.50"),
    output_price_per_million: Decimal.new("10.00"),
    supports_function_calling: true
  },
  %{
    provider_slug: "cohere",
    model_id: "command-r",
    display_name: "Command R",
    max_input_tokens: 128_000,
    max_output_tokens: 4_096,
    input_price_per_million: Decimal.new("0.15"),
    output_price_per_million: Decimal.new("0.60"),
    supports_function_calling: true
  }
]

IO.puts("Seeding #{length(models)} models...")

Enum.each(models, fn model_attrs ->
  case Models.upsert_model(model_attrs) do
    {:ok, model} ->
      IO.puts("  ✓ #{model.provider_slug}/#{model.model_id}")

    {:error, changeset} ->
      IO.puts("  ✗ #{model_attrs.provider_slug}/#{model_attrs.model_id}: #{inspect(changeset.errors)}")
  end
end)

IO.puts("Done!")
