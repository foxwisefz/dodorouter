defmodule DodoRouterWeb.ProviderComponents do
  @moduledoc """
  One way to offer a provider key for selection.

  There were three: the evaluation form named the provider but not the key
  hint, the routing-step form named the hint but not the provider, and the
  replay form named neither consistently. The same key therefore read
  differently on three pages — and on the evaluation form two genuinely
  different credentials rendered as the identical string "Moonshot · Key 1",
  because the label came from the adapter's name rather than the key slug's.

  A key is identified by three things, and a picker needs all three: which
  product it bills (`Moonshot Coding` is not `Moonshot`), which of your keys
  it is (`Key 1`), and which secret that is (`sk-••••Ly1`) for when the
  labels are as unhelpful as sequential numbers. Health comes fourth,
  because offering a key already known to be exhausted is how a benchmark
  gets spent on a credential that cannot work.
  """

  use Phoenix.Component

  alias DodoRouter.Providers
  alias DodoRouter.Providers.ProviderKey
  alias DodoRouter.Proxy.Adapter.Registry

  @doc """
  The single label for a provider key, wherever it is offered.

  `Moonshot Coding · Key 1 · sk-••••Ly1 · out of quota`
  """
  def provider_key_option_label(%ProviderKey{} = key) do
    [
      Registry.display_info(key.provider_slug).name,
      key_name(key),
      Providers.compact_key_hint(key.key_hint),
      health_suffix(key.status)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp key_name(%{label: label}) when label in [nil, ""], do: "unlabelled"
  defp key_name(%{label: label}), do: label

  # Only settled facts about the credential. A rate limit clears on its own
  # and would be noise on every option after any busy afternoon.
  defp health_suffix("quota_exceeded"), do: "out of quota"
  defp health_suffix("invalid"), do: "not authenticating"
  defp health_suffix(_status), do: nil

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :keys, :list, required: true
  attr :prompt, :string, default: nil
  attr :class, :string, default: "select select-sm w-full"
  attr :rest, :global

  @doc """
  A `<select>` over provider keys, labelled the one way.

  Takes plain `%ProviderKey{}` structs so every caller — evaluation form,
  routing step, replay — can feed it whatever it already has loaded.
  """
  def provider_key_select(assigns) do
    ~H"""
    <select id={@id} name={@name} class={@class} {@rest}>
      <option :if={@prompt} value="">{@prompt}</option>
      <%!-- Labelled, never disabled. A key's health is what we last saw,
      not what is true now — a quota resets, and a key you cannot select is
      a key that can never record the success that would clear its status. --%>
      <option :for={key <- @keys} value={key.id} selected={to_string(@value) == to_string(key.id)}>
        {provider_key_option_label(key)}
      </option>
    </select>
    """
  end
end
