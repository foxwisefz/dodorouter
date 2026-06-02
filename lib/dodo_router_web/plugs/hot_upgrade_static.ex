defmodule DodoRouterWeb.HotUpgradeStatic do
  @moduledoc """
  Wrapper around Plug.Static that supports OTP hot upgrades by searching
  across all installed release versions for static assets.

  After a hot upgrade, old LiveView processes may still reference assets
  from the previous release (different fingerprints). This plug searches
  all versions so old assets continue to be served until old processes
  are fully phased out.
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    opts
  end

  @impl Plug
  def call(conn, opts) do
    app = opts[:from]
    app_dir = Application.app_dir(app)

    # Check current version first (fast path for new assets)
    case Plug.Static.call(conn, get_initialized(opts, app_dir)) do
      %{status: 404} = conn ->
        # Asset not found in current version, search older versions
        try_fallback_versions(conn, opts, app)

      conn ->
        conn
    end
  end

  defp try_fallback_versions(conn, opts, app) do
    app_dir = Application.app_dir(app)
    lib_dir = Path.dirname(app_dir)
    app_name = "#{app}-"

    # Find all installed versions of this app, sorted newest first
    fallback_dirs =
      case File.ls(lib_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&String.starts_with?(&1, app_name))
          |> Enum.sort(:desc)
          |> Enum.map(&Path.join(lib_dir, &1))
          |> Enum.reject(&(&1 == app_dir))

        _ ->
          []
      end

    # Try each older version until we find the asset
    Enum.reduce_while(fallback_dirs, conn, fn dir, acc ->
      case Plug.Static.call(acc, get_initialized(opts, dir)) do
        %{status: 404} -> {:cont, acc}
        conn -> {:halt, conn}
      end
    end)
  end

  # Cache initialized Plug.Static globally per directory using :persistent_term.
  defp get_initialized(opts, dir) do
    cache_key = {:hot_upgrade_static, dir}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        opts = Keyword.put(opts, :from, dir)
        initialized = Plug.Static.init(opts)
        :persistent_term.put(cache_key, initialized)
        initialized

      initialized ->
        initialized
    end
  end
end
