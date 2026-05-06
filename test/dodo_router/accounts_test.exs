defmodule DodoRouter.AccountsTest do
  use DodoRouter.DataCase, async: true

  alias DodoRouter.Accounts
  import DodoRouter.AccountsFixtures

  describe "update_user_preferences/2" do
    test "updates sidebar_collapsed" do
      user = user_fixture()
      assert user.sidebar_collapsed == false

      {:ok, updated} = Accounts.update_user_preferences(user, %{sidebar_collapsed: true})
      assert updated.sidebar_collapsed == true
    end

    test "updates theme" do
      user = user_fixture()
      assert user.theme == "light"

      {:ok, updated} = Accounts.update_user_preferences(user, %{theme: "dark"})
      assert updated.theme == "dark"
    end

    test "updates theme to system" do
      user = user_fixture()

      {:ok, updated} = Accounts.update_user_preferences(user, %{theme: "system"})
      assert updated.theme == "system"
    end

    test "returns error for invalid theme" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.update_user_preferences(user, %{theme: "neon"})
      assert %{theme: ["is invalid"]} = errors_on(changeset)
    end

    test "can update both preferences at once" do
      user = user_fixture()

      {:ok, updated} =
        Accounts.update_user_preferences(user, %{sidebar_collapsed: true, theme: "dark"})

      assert updated.sidebar_collapsed == true
      assert updated.theme == "dark"
    end
  end
end
