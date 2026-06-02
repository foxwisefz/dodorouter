defmodule DodoRouterWeb.HotUpgradeStatic do
  @moduledoc """
  Wrapper around Plug.Static that resolves application directories at runtime
  rather than compile time. This ensures static assets are correctly served
  after OTP hot upgrades when the application directory changes.
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    opts
  end

  @impl Plug
  def call(conn, opts) do
    opts = resolve_from_paths(opts)
    initialized = get_initialized(opts)
    Plug.Static.call(conn, initialized)
  end

  defp resolve_from_paths(opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, app} when is_atom(app) ->
        Keyword.put(opts, :from, Application.app_dir(app))

      {:ok, {:otp_app, app}} when is_atom(app) ->
        Keyword.put(opts, :from, Application.app_dir(app))

      _ ->
        opts
    end
  end

  # Cache initialized Plug.Static globally per version using :persistent_term.
  # This is an ETS-based store optimized for read-heavy workloads with O(1) lookups.
  # The cache is shared across all processes and re-initializes only after hot upgrades.
  defp get_initialized(opts) do
    current_vsn = Application.spec(:dodo_router, :vsn)
    cache_key = {:hot_upgrade_static, current_vsn}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        initialized = Plug.Static.init(opts)
        :persistent_term.put(cache_key, initialized)
        initialized

      initialized ->
        initialized
    end
  end
end
