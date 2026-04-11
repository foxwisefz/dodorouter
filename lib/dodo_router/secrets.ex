defmodule DodoRouter.Secrets do
  @moduledoc """
  Secrets management via Infisical.

  Uses folder structure:
    /dodorouter/projects/{project_id}/{provider}_api_key

  Project ID is used for organization. Provider credentials are stored as:
    - zai_api_key
    - moonshot_api_key
  """

  require Logger

  @cache_ttl_ms 5 * 60 * 1000
  @infisical_api "https://app.infisical.com/api/v4/secrets"

  # Public API

  def get(project_id, secret_name) do
    cache_key = "#{project_id}/#{secret_name}"

    case get_cached(cache_key) do
      {:ok, value} -> value
      :miss -> fetch_and_cache(project_id, secret_name, cache_key)
    end
  end

  def put(project_id, secret_name, value) do
    cache_key = "#{project_id}/#{secret_name}"

    case put_to_infisical(project_id, secret_name, value) do
      :ok ->
        put_cache(cache_key, value)
        :ok

      error ->
        error
    end
  end

  def delete(project_id, secret_name) do
    cache_key = "#{project_id}/#{secret_name}"
    result = delete_from_infisical(project_id, secret_name)
    invalidate_cache(cache_key)
    result
  end

  def list(project_id) do
    list_from_infisical(project_id)
  end

  # Convenience getters for provider API keys
  def zai_api_key(project_id), do: get(project_id, "zai_api_key")
  def moonshot_api_key(project_id), do: get(project_id, "moonshot_api_key")

  # Private - Paths

  defp secret_path(project_id) do
    "/dodorouter/projects/#{project_id}"
  end

  # Private - Infisical API

  defp fetch_and_cache(project_id, secret_name, cache_key) do
    case fetch_from_infisical(project_id, secret_name) do
      {:ok, value} ->
        put_cache(cache_key, value)
        value

      {:error, reason} ->
        Logger.debug("Infisical fetch failed for #{cache_key}: #{inspect(reason)}")
        nil
    end
  end

  defp fetch_from_infisical(project_id, secret_name) do
    with {:ok, config} <- get_infisical_config() do
      path = secret_path(project_id)

      url =
        "https://app.infisical.com/api/v3/secrets/raw/#{secret_name}?" <>
          URI.encode_query(%{
            "workspaceId" => config.project_id,
            "environment" => config.env,
            "secretPath" => path
          })

      headers = [{"Authorization", "Bearer #{config.token}"}]

      case Req.get(url, headers: headers) do
        {:ok, %{status: 200, body: %{"secret" => %{"secretValue" => value}}}} ->
          {:ok, value}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp put_to_infisical(project_id, secret_name, value) do
    with {:ok, config} <- get_infisical_config() do
      path = secret_path(project_id)
      url = "#{@infisical_api}/#{secret_name}"

      headers = [
        {"Authorization", "Bearer #{config.token}"},
        {"Content-Type", "application/json"}
      ]

      body = %{
        "projectId" => config.project_id,
        "environment" => config.env,
        "secretPath" => path,
        "secretValue" => value
      }

      case Req.post(url, headers: headers, json: body) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: 400, body: %{"message" => msg}}} when is_binary(msg) ->
          if String.contains?(msg, "exist") do
            update_in_infisical(project_id, secret_name, value, config)
          else
            {:error, {:create_failed, msg}}
          end

        {:ok, %{status: 404, body: %{"message" => msg}}} when is_binary(msg) ->
          if String.contains?(msg, "Folder") do
            case ensure_project_folder(project_id, config) do
              :ok -> put_to_infisical(project_id, secret_name, value)
              error -> error
            end
          else
            {:error, {:http_error, 404, msg}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_project_folder(project_id, config) do
    headers = [
      {"Authorization", "Bearer #{config.token}"},
      {"Content-Type", "application/json"}
    ]

    projects_body = %{
      "workspaceId" => config.project_id,
      "environment" => config.env,
      "name" => "projects",
      "path" => "/"
    }

    Req.post("https://app.infisical.com/api/v1/folders", headers: headers, json: projects_body)

    project_body = %{
      "workspaceId" => config.project_id,
      "environment" => config.env,
      "name" => to_string(project_id),
      "path" => "/projects"
    }

    case Req.post("https://app.infisical.com/api/v1/folders", headers: headers, json: project_body) do
      {:ok, %{status: status}} when status in [200, 201, 400] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:folder_create_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_in_infisical(project_id, secret_name, value, config) do
    path = secret_path(project_id)
    url = "#{@infisical_api}/#{secret_name}"

    headers = [
      {"Authorization", "Bearer #{config.token}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "projectId" => config.project_id,
      "environment" => config.env,
      "secretPath" => path,
      "secretValue" => value
    }

    case Req.patch(url, headers: headers, json: body) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_from_infisical(project_id, secret_name) do
    with {:ok, config} <- get_infisical_config() do
      path = secret_path(project_id)

      url =
        "#{@infisical_api}/#{secret_name}/raw?" <>
          URI.encode_query(%{
            "projectId" => config.project_id,
            "environment" => config.env,
            "secretPath" => path
          })

      headers = [{"Authorization", "Bearer #{config.token}"}]

      case Req.delete(url, headers: headers) do
        {:ok, %{status: status}} when status in [200, 204] ->
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp list_from_infisical(project_id) do
    with {:ok, config} <- get_infisical_config() do
      path = secret_path(project_id)

      url =
        "https://app.infisical.com/api/v4/secrets?" <>
          URI.encode_query(%{
            "projectId" => config.project_id,
            "environment" => config.env,
            "secretPath" => path
          })

      headers = [{"Authorization", "Bearer #{config.token}"}]

      case Req.get(url, headers: headers) do
        {:ok, %{status: 200, body: %{"secrets" => secrets}}} ->
          {:ok, Enum.map(secrets, fn s -> {s["secretKey"], s["secretValue"]} end)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp get_infisical_config do
    token = System.get_env("INFISICAL_TOKEN")
    project_id = System.get_env("INFISICAL_PROJECT_ID")
    env = System.get_env("INFISICAL_ENVIRONMENT", "prod")

    if token && project_id do
      {:ok, %{token: token, project_id: project_id, env: env}}
    else
      {:error, :not_configured}
    end
  end

  # Cache (simple ETS)

  defp cache_table, do: :dodo_secrets_cache

  defp ensure_cache_table do
    case :ets.whereis(cache_table()) do
      :undefined ->
        try do
          :ets.new(cache_table(), [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp get_cached(key) do
    ensure_cache_table()

    case :ets.lookup(cache_table(), key) do
      [{^key, value, expires_at}] ->
        if expires_at > System.system_time(:millisecond) do
          {:ok, value}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  defp put_cache(key, value) do
    ensure_cache_table()
    expires_at = System.system_time(:millisecond) + @cache_ttl_ms
    :ets.insert(cache_table(), {key, value, expires_at})
    :ok
  end

  defp invalidate_cache(key) do
    ensure_cache_table()
    :ets.delete(cache_table(), key)
    :ok
  end
end
