defmodule DodoRouter.Models do
  @moduledoc """
  Context for managing model capabilities and pricing.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Models.Model
  alias DodoRouter.Usage

  def list_models do
    Repo.all(from m in Model, order_by: [asc: m.provider_slug, asc: m.model_id])
  end

  def list_models_by_provider(provider_slug) do
    Repo.all(from m in Model, where: m.provider_slug == ^provider_slug, order_by: m.model_id)
  end

  @doc """
  Models of a provider that may be offered for selection.

  models.dev publishes no deprecation field — a retired model is simply
  absent from `api.json` — so "seen in the most recent sync" is the only
  retirement signal there is. Anything the newest sync did not touch is
  assumed gone.

  Two deliberate escapes. A catalog whose freshest entry is older than
  `@catalog_trust_window` tells us nothing about what is retired, so
  everything is offered rather than nothing: a sync that stopped running
  must not empty every picker. And a row never stamped at all — written
  before this column, or upserted by us rather than synced — is kept, since
  absence of evidence is not retirement.

  Pricing lookups do not go through here: a model can be retired upstream
  while requests naming it are still in flight, and their cost still has to
  be computed from something.
  """
  @catalog_trust_window_days 7

  def offerable_models(provider_slug) do
    case latest_sync_at(provider_slug) do
      nil ->
        list_models_by_provider(provider_slug)

      latest ->
        if DateTime.diff(DateTime.utc_now(), latest, :day) > @catalog_trust_window_days do
          list_models_by_provider(provider_slug)
        else
          from(m in Model,
            where:
              m.provider_slug == ^provider_slug and
                (is_nil(m.last_seen_at) or m.last_seen_at >= ^latest),
            order_by: m.model_id
          )
          |> Repo.all()
        end
    end
  end

  @doc "When this provider's catalog was last refreshed, or nil if never."
  def latest_sync_at(provider_slug) do
    Repo.one(
      from(m in Model, where: m.provider_slug == ^provider_slug, select: max(m.last_seen_at))
    )
  end

  def get_model(id), do: Repo.get(Model, id)

  def get_model_by_id(provider_slug, model_id) do
    Repo.get_by(Model, provider_slug: provider_slug, model_id: model_id)
  end

  # Coding-plan catalogs sometimes alias models the metered API lists under
  # different ids (kimi-for-coding's "k2p5" is metered "kimi-k2.5" — the p
  # is "point"). Consulted only after the literal id misses, and only for
  # list-price lookups.
  @metered_aliases %{
    "moonshot" => %{
      "k2p5" => "kimi-k2.5",
      "k2p6" => "kimi-k2.6",
      "k2p7" => "kimi-k2.7-code"
    }
  }

  @doc """
  The metered (pay-as-you-go) catalog row for a model, resolving
  plan-catalog alias ids when the literal id has no metered row.

  Router provider slugs that front another provider's catalog are normalized
  first (e.g. "openai-codex" serves OpenAI models, priced under "openai").

  Backs list-price ("would cost") calculations for plan-based traffic.
  """
  def get_metered_model(provider_slug, model_id) do
    provider_slug = normalize_provider_slug(provider_slug)

    get_model_by_id(provider_slug, model_id) ||
      case get_in(@metered_aliases, [provider_slug, model_id]) do
        nil -> nil
        aliased_id -> get_model_by_id(provider_slug, aliased_id)
      end
  end

  def get_model!(id), do: Repo.get!(Model, id)

  @doc """
  Returns the reasoning effort levels a model is known to accept (synced from
  models.dev), or `[]` when the model is unknown or has no effort-style
  reasoning control.

  Router provider slugs that front another provider's models are normalized
  to the models.dev provider (e.g. "openai-codex" serves OpenAI models).
  """
  def reasoning_efforts_for(provider_slug, model_id) do
    case get_model_by_id(normalize_provider_slug(provider_slug), model_id) do
      %Model{reasoning_efforts: efforts} when is_list(efforts) -> efforts
      _ -> []
    end
  end

  defp normalize_provider_slug("openai-codex"), do: "openai"
  defp normalize_provider_slug(slug), do: slug

  def create_model(attrs \\ %{}) do
    %Model{}
    |> Model.changeset(attrs)
    |> Repo.insert()
  end

  def update_model(%Model{} = model, attrs) do
    model
    |> Model.changeset(attrs)
    |> Repo.update()
  end

  def delete_model(%Model{} = model) do
    Repo.delete(model)
  end

  def upsert_model(attrs) do
    %Model{}
    |> Model.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:provider_slug, :model_id]
    )
  end

  @doc """
  Check if a model supports the required capabilities for an eval case.
  Returns {:ok, model} or {:error, :missing_capabilities, list}
  """
  def check_capabilities(%Model{} = model, required_capabilities) do
    missing =
      Enum.filter(required_capabilities, fn cap ->
        not Map.get(model, cap, false)
      end)

    case missing do
      [] -> {:ok, model}
      caps -> {:error, :missing_capabilities, caps}
    end
  end

  @doc """
  Filter models that support all given capabilities.
  """
  def filter_by_capabilities(capabilities) when is_list(capabilities) do
    base_query = from(m in Model)

    Enum.reduce(capabilities, base_query, fn cap, query ->
      case cap do
        :supports_vision -> from(m in query, where: m.supports_vision == true)
        :supports_audio_input -> from(m in query, where: m.supports_audio_input == true)
        :supports_audio_output -> from(m in query, where: m.supports_audio_output == true)
        :supports_function_calling -> from(m in query, where: m.supports_function_calling == true)
        :supports_streaming -> from(m in query, where: m.supports_streaming == true)
        :supports_system_messages -> from(m in query, where: m.supports_system_messages == true)
        :supports_response_schema -> from(m in query, where: m.supports_response_schema == true)
        :supports_reasoning -> from(m in query, where: m.supports_reasoning == true)
        :supports_prompt_caching -> from(m in query, where: m.supports_prompt_caching == true)
        _ -> query
      end
    end)
    |> Repo.all()
  end

  @doc """
  Calculate cost for a request given token counts including cache.
  Returns cost in USD.

  Cache reads are typically cheaper (e.g., 10% of input price for Anthropic),
  cache writes are typically more expensive (e.g., 125% of input price).
  """
  def calculate_cost(%Model{} = model, input_tokens, output_tokens, opts \\ []) do
    cache_read_tokens = Keyword.get(opts, :cache_read_tokens, 0) || 0
    cache_write_tokens = Keyword.get(opts, :cache_write_tokens, 0) || 0

    # Cache reads/writes are billed at their own rates, so only what's left
    # pays the regular input price. Whether `input_tokens` already contains
    # the cache figures depends on the provider — `Usage` decides.
    regular_input = Usage.new_input_tokens(input_tokens, cache_read_tokens, cache_write_tokens)

    input_cost = decimal_cost(model.input_price_per_million, regular_input)
    output_cost = decimal_cost(model.output_price_per_million, output_tokens)
    cache_read_cost = decimal_cost(model.cache_read_price_per_million, cache_read_tokens)
    cache_write_cost = decimal_cost(model.cache_write_price_per_million, cache_write_tokens)

    Decimal.add(input_cost, output_cost)
    |> Decimal.add(cache_read_cost)
    |> Decimal.add(cache_write_cost)
  end

  defp decimal_cost(nil, _tokens), do: Decimal.new(0)
  defp decimal_cost(_price, 0), do: Decimal.new(0)
  defp decimal_cost(price, tokens), do: Decimal.mult(price, Decimal.div(tokens, 1_000_000))
end
