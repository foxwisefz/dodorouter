defmodule DodoRouter.Models.Sync do
  @moduledoc """
  Syncs model data (pricing, capabilities, limits) from models.dev API.

  models.dev is an open-source database of AI models maintained by the SST team.
  API: https://models.dev/api.json
  """

  require Logger

  alias DodoRouter.Models

  @models_dev_url "https://models.dev/api.json"

  # Keys are models.dev provider ids, values are our adapter slugs.
  # models.dev keys Moonshot under "moonshotai" — a bare "moonshot" key
  # doesn't exist there and silently dropped every Kimi model.
  @provider_slug_map %{
    "anthropic" => "anthropic",
    "openai" => "openai",
    "google" => "google",
    "groq" => "groq",
    "mistral" => "mistral",
    "xai" => "xai",
    "deepseek" => "deepseek",
    "cohere" => "cohere",
    "moonshotai" => "moonshot",
    "zai" => "zai"
  }

  @doc """
  Maps a models.dev provider key to our adapter slug (nil = not synced).
  """
  def dodo_slug_for(models_dev_key), do: Map.get(@provider_slug_map, models_dev_key)

  @doc """
  Fetches models from models.dev and upserts them into the database.
  Returns {:ok, count} or {:error, reason}.
  """
  def sync_from_models_dev do
    case fetch_models() do
      {:ok, providers} ->
        count =
          providers
          |> Enum.flat_map(&parse_provider_models/1)
          |> Enum.filter(&(&1 != nil))
          |> Enum.count(fn attrs ->
            case Models.upsert_model(attrs) do
              {:ok, _} ->
                true

              {:error, changeset} ->
                Logger.warning(
                  "Failed to upsert model #{inspect(attrs[:model_id])}: #{inspect(changeset.errors)}"
                )

                false
            end
          end)

        {:ok, count}

      {:error, reason} ->
        Logger.error("Failed to fetch models from models.dev: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_models do
    case Req.get(@models_dev_url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_provider_models({provider_key, provider_data}) do
    dodo_slug = dodo_slug_for(provider_key)
    models = provider_data["models"] || %{}

    if dodo_slug == nil do
      []
    else
      Enum.map(models, fn {model_id, model_data} ->
        parse_model(dodo_slug, model_id, model_data)
      end)
    end
  end

  defp parse_model(provider_slug, model_id, data) do
    cost = data["cost"] || %{}
    limit = data["limit"] || %{}
    modalities = data["modalities"] || %{}

    %{
      provider_slug: provider_slug,
      model_id: model_id,
      display_name: data["name"] || model_id,
      max_input_tokens: limit["context"],
      max_output_tokens: limit["output"],
      input_price_per_million: to_decimal(cost["input"]),
      output_price_per_million: to_decimal(cost["output"]),
      cache_read_price_per_million: to_decimal(cost["cache_read"]),
      cache_write_price_per_million: to_decimal(cost["cache_write"]),
      supports_vision: "image" in (modalities["input"] || []),
      supports_audio_input: "audio" in (modalities["input"] || []),
      supports_function_calling: data["tool_call"] == true,
      supports_streaming: true,
      supports_system_messages: true,
      supports_reasoning: data["reasoning"] == true,
      supports_response_schema: data["structured_output"] == true,
      supports_prompt_caching: cost["cache_read"] != nil || cost["cache_write"] != nil,
      reasoning_efforts: parse_reasoning_efforts(data["reasoning_options"])
    }
  end

  # reasoning_options is a list of option specs, e.g.
  #   [%{"type" => "effort", "values" => ["low", "high", "xhigh"]}]
  # possibly alongside "toggle" / "budget_tokens" entries. We only extract the
  # effort values; other option types don't map to a step-level effort list.
  defp parse_reasoning_efforts(options) when is_list(options) do
    Enum.find_value(options, [], fn
      %{"type" => "effort", "values" => values} when is_list(values) ->
        Enum.filter(values, &is_binary/1)

      _ ->
        nil
    end)
  end

  defp parse_reasoning_efforts(_), do: []

  defp to_decimal(nil), do: nil
  defp to_decimal(number) when is_number(number), do: Decimal.new("#{number}")

  defp to_decimal(string) when is_binary(string) do
    case Decimal.parse(string) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end
end
