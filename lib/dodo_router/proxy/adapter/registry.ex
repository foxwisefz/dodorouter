defmodule DodoRouter.Proxy.Adapter.Registry do
  @moduledoc """
  Central registry for LLM provider adapters.

  Each adapter module calls `use DodoRouter.Proxy.Adapter.Registry` with its
  configuration, and this module collects them all so that consumers
  (RoutingStep, ProviderKey, FallbackChain, LiveViews) can query provider
  info without hardcoding provider lists.

  To add a new provider, create a single adapter module that `use`s this
  module AND add it to @adapter_modules below.
  """

  # Explicit list of all adapter modules - add new adapters here
  @adapter_modules [
    DodoRouter.Proxy.Adapters.OpenAI,
    DodoRouter.Proxy.Adapters.OpenAICodex,
    DodoRouter.Proxy.Adapters.Anthropic,
    DodoRouter.Proxy.Adapters.Google,
    DodoRouter.Proxy.Adapters.Groq,
    DodoRouter.Proxy.Adapters.Mistral,
    DodoRouter.Proxy.Adapters.XAI,
    DodoRouter.Proxy.Adapters.DeepSeek,
    DodoRouter.Proxy.Adapters.Cohere,
    DodoRouter.Proxy.Adapters.Moonshot,
    DodoRouter.Proxy.Adapters.Zai,
    DodoRouter.Proxy.Adapters.TestProvider
  ]

  @type oauth_config :: %{
          authorization_url: String.t(),
          token_url: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          scope: String.t(),
          redirect_uri: String.t()
        }

  @type adapter_config :: %{
          slug: String.t(),
          display_name: String.t(),
          module: module(),
          key_slugs: [String.t()],
          key_generation_url: String.t() | nil,
          oauth_config: oauth_config() | nil,
          endpoints: %{String.t() => String.t()},
          endpoint_path: String.t(),
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
          key_display_names: unquote(opts[:key_display_names]),
          key_generation_url: unquote(opts[:key_generation_url]),
          oauth_config: unquote(opts[:oauth_config]),
          endpoints: unquote(opts[:endpoints]),
          # Request path appended to the endpoint base URL; used for display
          # in logs ("{model}" is replaced with the step's model).
          endpoint_path: unquote(opts[:endpoint_path] || "/chat/completions"),
          # The wire format of the request this adapter builds. When it matches
          # the format the client spoke, the request needs no translation and
          # fields the OpenAI-shaped IR cannot carry are passed through
          # untouched (see `FallbackChain` and `AnthropicFormat`). Declared
          # rather than inferred from `endpoint_path`: the path is a URL detail
          # that happens to correlate today, and a provider moving its route
          # must not silently change what we forward.
          request_format: unquote(opts[:request_format] || :openai),
          # Only for providers with nothing upstream to sync; models.dev is
          # the source for everyone else.
          models: unquote(opts[:models] || []),
          color: unquote(opts[:color]),
          short_description: unquote(opts[:short_description]),
          # Optional per-key-slug descriptions; falls back to short_description
          key_short_descriptions: unquote(opts[:key_short_descriptions])
        }
      end
    end
  end

  @doc false
  def registered_modules do
    @adapter_modules
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
  The wire format an adapter module builds its upstream request in.

  `:openai` unless the adapter says otherwise, because that is the shape of the
  intermediate representation every ingress converts to.
  """
  @spec request_format(module() | nil) :: atom()
  def request_format(nil), do: nil

  def request_format(module) when is_atom(module) do
    module.adapter_config().request_format
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

  The name is the **key slug's** name, not the adapter's: a provider's
  pay-as-you-go API and its flat-rate coding plan share an adapter but are
  different credentials, with different quotas and base URLs. Falling back
  to the adapter's `display_name` for both is what rendered two distinct
  keys in a picker as the same string, with no way to tell them apart.

  `provider_info/0` has always honoured `key_display_names`; these two
  disagreeing meant one key read differently depending on the page.
  """
  @spec display_info(String.t()) :: %{name: String.t(), provider: String.t()}
  def display_info(key_slug) do
    Enum.find_value(all_adapters(), fn {_slug, config} ->
      if key_slug in config.key_slugs do
        %{
          name: Map.get(config.key_display_names || %{}, key_slug, config.display_name),
          provider: config.slug
        }
      end
    end) || %{name: "Unknown", provider: nil}
  end

  @doc """
  Returns the list of available models for a provider slug.
  """
  @spec available_models(String.t()) :: [String.t()]
  def available_models(provider_slug) do
    case Map.get(all_adapters(), provider_slug) do
      %{models: models} when is_list(models) -> models
      _ -> []
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
        name = Map.get(config.key_display_names || %{}, key_slug, config.display_name)

        short =
          Map.get(config[:key_short_descriptions] || %{}, key_slug, config.short_description)

        {key_slug,
         %{
           name: name,
           short: short,
           endpoint: Map.get(config.endpoints, key_slug),
           color: config.color,
           key_generation_url: config.key_generation_url,
           oauth_config: config.oauth_config
         }}
      end
    end)
    |> Map.new()
  end
end
