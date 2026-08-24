defmodule DodoRouter.AuthZ.Keystore do
  @moduledoc """
  The signing key for issued access tokens.

  Production reads it from the environment and fails loudly if it is absent —
  a server that silently invents a signing key on boot would issue tokens that
  every other node rejects, and would invalidate every live token on restart.

  Development generates one and keeps it in `priv/dev/`, so a restart does not
  log the developer's agent out. That file is dev-only key material and is
  gitignored.
  """

  @behaviour Attesto.Keystore

  @env_var "ATTESTO_SIGNING_KEY_PEM"
  @path_var "ATTESTO_SIGNING_KEY_PATH"
  @dev_path "priv/dev/oauth_signing_key.pem"

  @impl true
  def signing_pem do
    case System.get_env(@env_var) do
      pem when is_binary(pem) and pem != "" -> pem
      _ -> path_pem() || dev_pem()
    end
  end

  # A PEM is multi-line and systemd's EnvironmentFile cannot carry multi-line
  # values, so the inline variable can never travel through the production
  # unit's ~/.env — this path variant is how production configures the key.
  # Read on every call rather than cached: signing happens at token mint, which
  # is rare, and a cache would be one more copy to go stale across upgrades.
  defp path_pem do
    case System.get_env(@path_var) do
      path when is_binary(path) and path != "" ->
        case File.read(path) do
          {:ok, pem} when pem != "" ->
            pem

          other ->
            raise """
            #{@path_var} is set to #{path}, but the key could not be read \
            (#{inspect(other)}).

            A signing key that half-exists must not fall through to any other \
            source: tokens signed with a different key than the operator \
            intended would all be invalidated when the mistake is found.
            """
        end

      _ ->
        nil
    end
  end

  @impl true
  def verification_pems, do: [signing_pem()]

  # EC P-256: small, fast, and what ES256 — the default every OAuth client
  # supports — is defined over.
  @impl true
  def signing_alg, do: "ES256"

  defp dev_pem do
    unless Application.get_env(:dodo_router, :env) in [:dev, :test] do
      raise """
      Neither #{@env_var} nor #{@path_var} is set.

      The authorization server needs a stable signing key. Generate one with:

          openssl ecparam -name prime256v1 -genkey -noout -out oauth_signing_key.pem
          chmod 600 oauth_signing_key.pem

      and set #{@path_var} to its absolute path (a PEM is multi-line, which
      systemd's EnvironmentFile cannot express inline). Do not let production
      fall back to a generated key: tokens would not survive a restart, and no
      two nodes would agree.
      """
    end

    path = Path.join(:code.priv_dir(:dodo_router) |> to_string(), "dev/oauth_signing_key.pem")

    case File.read(path) do
      {:ok, pem} ->
        pem

      {:error, _} ->
        pem = generate_pem()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, pem)
        File.chmod!(path, 0o600)
        pem
    end
  end

  defp generate_pem do
    {_pub, _priv} = key = :crypto.generate_key(:ecdh, :secp256r1)

    key
    |> then(fn {pub, priv} ->
      {:ECPrivateKey, 1, priv, {:namedCurve, :pubkey_cert_records.namedCurves(:secp256r1)}, pub,
       :asn1_NOVALUE}
    end)
    |> then(&:public_key.pem_entry_encode(:ECPrivateKey, &1))
    |> List.wrap()
    |> :public_key.pem_encode()
  end

  @doc false
  def dev_key_path, do: @dev_path
end
