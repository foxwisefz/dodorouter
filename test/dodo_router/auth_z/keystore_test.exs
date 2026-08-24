defmodule DodoRouter.AuthZ.KeystoreTest do
  # Mutates process-global env vars, so never concurrent with anything.
  use ExUnit.Case, async: false

  alias DodoRouter.AuthZ.Keystore

  @pem_var "ATTESTO_SIGNING_KEY_PEM"
  @path_var "ATTESTO_SIGNING_KEY_PATH"

  setup do
    original = {System.get_env(@pem_var), System.get_env(@path_var)}
    System.delete_env(@pem_var)
    System.delete_env(@path_var)

    on_exit(fn ->
      {pem, path} = original
      if pem, do: System.put_env(@pem_var, pem), else: System.delete_env(@pem_var)
      if path, do: System.put_env(@path_var, path), else: System.delete_env(@path_var)
    end)

    :ok
  end

  test "reads the key from the file ATTESTO_SIGNING_KEY_PATH names" do
    # systemd's EnvironmentFile cannot carry a multi-line value, so a PEM can
    # never travel through ATTESTO_SIGNING_KEY_PEM in the production unit —
    # the path variant is how production actually configures the key.
    path = Path.join(System.tmp_dir!(), "keystore_test_#{System.unique_integer([:positive])}.pem")
    File.write!(path, "-----BEGIN EC PRIVATE KEY-----\nfrom-file\n-----END EC PRIVATE KEY-----\n")
    on_exit(fn -> File.rm(path) end)

    System.put_env(@path_var, path)

    assert Keystore.signing_pem() =~ "from-file"
  end

  test "an inline PEM still wins over the path" do
    path = Path.join(System.tmp_dir!(), "keystore_test_#{System.unique_integer([:positive])}.pem")
    File.write!(path, "from-file")
    on_exit(fn -> File.rm(path) end)

    System.put_env(@path_var, path)
    System.put_env(@pem_var, "inline-pem")

    assert Keystore.signing_pem() == "inline-pem"
  end

  test "a path that does not exist fails loudly, not silently" do
    System.put_env(@path_var, "/nonexistent/oauth_signing_key.pem")

    assert_raise RuntimeError, ~r/ATTESTO_SIGNING_KEY_PATH/, fn -> Keystore.signing_pem() end
  end
end
