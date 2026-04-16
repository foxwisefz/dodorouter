defmodule DodoRouter.Proxy.Adapter.Registry do
  @moduledoc """
  Central registry for LLM provider adapters.

  Each adapter module calls `use DodoRouter.Proxy.Adapter.Registry` with its
  configuration, and this module collects them all so that consumers
  (RoutingStep, ProviderKey, FallbackChain, LiveViews) can query provider
  info without hardcoding provider lists.

  To add a new provider, create a single adapter module that `use`s this
  module — no other file needs to change.
  """

  @type adapter_config :: %{
          slug: String.t(),
          display_name: String.t(),
          module: module(),
          key_slugs: [String.t()],
          endpoints: %{String.t() => String.t()},
          models: [String.t()],
          color: String.t(),
          short_description: String.t()
        }

  @doc """
  Returns the config for this adapter module.
  """
  @callback adapter_config() :: adapter_config()

  defmacro __using__(opts) do
    quote do
      @behaviour DodoRouter.Proxy.Adapter

      def adapter_config do
        %{
          slug: unquote(opts[:slug]),
          display_name: unquote(opts[:display_name]),
          module: __MODULE__,
          key_slugs: unquote(opts[:key_slugs]),
          endpoints: unquote(opts[:endpoints]),
          models: unquote(opts[:models]),
          color: unquote(opts[:color]),
          short_description: unquote(opts[:short_description])
        }
      end

      # Register this adapter module in application env at compile time
      DodoRouter.Proxy.Adapter.Registry.__register__(__MODULE__)
    end
  end

  @doc false
  def __register__(module) do
    modules = registered_modules()

    unless module in modules do
      Application.put_env(:dodo_router, :adapter_modules, [module | modules])
    end
  end

  @doc false
  def registered_modules do
    Application.get_env(:dodo_router, :adapter_modules, [])
  end

  @doc """
  Returns all adapter configs as a map keyed by provider slug.
  """
  @spec all_adapters() :: %{String.t() => adapter_config()}
  def all_adapters do
    for module <- registered_modules(), into: %{} do
      config = module.adapter_config()
      {config.slug, config}
    end
  end

  @doc """
  Returns the list of all registered provider slugs.
  """
  @spec providers() :: [String.t()]
  def providers do
    all_adapters() |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns the adapter module for a given provider slug.
  """
  @spec adapter_for(String.t()) :: module() | nil
  def adapter_for(slug) do
    case Map.get(all_adapters(), slug) do
      %{module: module} -> module
      nil -> nil
    end
  end

  @doc """
  Returns all key slugs across all providers (flattened).
  """
  @spec provider_slugs() :: [String.t()]
  def provider_slugs do
    all_adapters()
    |> Enum.flat_map(fn {_slug, config} -> config.key_slugs end)
    |> Enum.sort()
  end

  @doc """
  Returns the base API endpoint URL for a provider key slug.
  """
  @spec endpoint_for(String.t()) :: String.t() | nil
  def endpoint_for(key_slug) do
    Enum.find_value(all_adapters(), fn {_slug, config} ->
      Map.get(config.endpoints, key_slug)
    end)
  end

  @doc """
  Returns display info for a provider key slug.
  """
  @spec display_info(String.t()) :: %{name: String.t(), provider: String.t()}
  def display_info(key_slug) do
    Enum.find_value(all_adapters(), fn {_slug, config} ->
      if key_slug in config.key_slugs do
        %{name: config.display_name, provider: config.slug}
      end
    end) || %{name: "Unknown", provider: nil}
  end

  @doc """
  Returns the list of available models for a provider slug.
  """
  @spec available_models(String.t()) :: [String.t()]
  def available_models(provider_slug) do
    case Map.get(all_adapters(), provider_slug) do
      %{models: models} -> models
      nil -> []
    end
  end

  @doc """
  Maps provider slug + plan_type to a key slug.
  """
  @spec to_key_slug(String.t(), String.t()) :: String.t()
  def to_key_slug(provider, plan_type) do
    case Map.get(all_adapters(), provider) do
      %{key_slugs: key_slugs} ->
        # Try to find a key slug matching the plan_type
        matching = Enum.find(key_slugs, &String.contains?(&1, plan_type))

        if matching do
          matching
        else
          List.first(key_slugs) || provider
        end

      nil ->
        provider
    end
  end

  @doc """
  Extracts provider name from key slug for adapter selection.
  """
  @spec adapter_provider(String.t()) :: String.t()
  def adapter_provider(key_slug) do
    Enum.find_value(all_adapters(), fn {_slug, config} ->
      if key_slug in config.key_slugs, do: config.slug
    end) || key_slug
  end

  @doc """
  Returns provider info map suitable for the providers LiveView.
  """
  @spec provider_info() :: %{String.t() => map()}
  def provider_info do
    all_adapters()
    |> Enum.flat_map(fn {_slug, config} ->
      for key_slug <- config.key_slugs do
        {key_slug,
         %{
           name: config.display_name,
           short: config.short_description,
           endpoint: Map.get(config.endpoints, key_slug),
           color: config.color
         }}
      end
    end)
    |> Map.new()
  end
end
