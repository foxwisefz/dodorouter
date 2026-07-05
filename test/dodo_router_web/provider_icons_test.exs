defmodule DodoRouterWeb.ProviderIconsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DodoRouterWeb.ProviderIcons

  # Matches one SVG path "d" attribute per icon and validates it parses as
  # SVG path data. A truncated paste (e.g. a literal "..." left in the data)
  # renders a broken icon and logs a console error on every page load.
  @path_data ~r/\sd="([^"]+)"/

  test "every provider icon has parseable SVG path data" do
    for slug <- ~w(openai anthropic deepseek google groq mistral moonshot xai zai cohere) do
      html =
        render_component(&ProviderIcons.provider_logo/1, %{slug: slug})

      for [d] <- Regex.scan(@path_data, html, capture: :all_but_first) do
        refute String.contains?(d, "..."),
               "#{slug} icon path contains a literal '...' (truncated path data)"

        # SVG path data may only contain command letters, digits, separators
        assert d =~ ~r/^[MmLlHhVvCcSsQqTtAaZz0-9\s,.+-eE]+$/,
               "#{slug} icon path contains invalid characters"
      end
    end
  end
end
