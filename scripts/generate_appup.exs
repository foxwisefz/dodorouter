#!/usr/bin/env elixir
# Auto-generates appup.ex from git diff between versions
# Usage: mix appup.generate 0.1.65 0.1.66

[old_vsn, new_vsn | _] = System.argv()

# Try tags first, fall back to the current checkout for the not-yet-tagged version
has_old_tag = System.cmd("git", ["tag", "-l", "v#{old_vsn}"]) |> elem(0) |> String.trim() != ""
has_new_tag = System.cmd("git", ["tag", "-l", "v#{new_vsn}"]) |> elem(0) |> String.trim() != ""

range = cond do
  has_old_tag and has_new_tag -> "v#{old_vsn}..v#{new_vsn}"
  has_old_tag -> "v#{old_vsn}..HEAD"
  has_new_tag -> "HEAD..v#{new_vsn}"
  true -> "HEAD"
end

# Get changed files between versions
{output, 0} = System.cmd("git", ["diff", "--name-only", range, "--", "lib/"])

changed_files = String.split(output, "\n")

# Extract modules from .ex files
ex_modules =
  changed_files
  |> Enum.filter(&String.ends_with?(&1, ".ex"))
  |> Enum.flat_map(fn file ->
    case File.read(file) do
      {:ok, content} ->
        Regex.scan(~r/^defmodule\s+([A-Za-z0-9._]+)\s+do/m, content)
        |> Enum.map(fn [_, mod] -> mod end)
      _ -> []
    end
  end)

# Map .html.heex files to their parent modules
heex_modules =
  changed_files
  |> Enum.filter(&String.ends_with?(&1, ".html.heex"))
  |> Enum.flat_map(fn file ->
    cond do
      # Layout templates compile into DodoRouterWeb.Layouts
      String.contains?(file, "components/layouts/") ->
        ["DodoRouterWeb.Layouts"]

      # Controller templates: controllers/user_session_html/new.html.heex → DodoRouterWeb.UserSessionHtml
      Regex.match?(~r|controllers/(.+)_html/|, file) ->
        [[_, dir]] = Regex.scan(~r|controllers/(.+)_html/|, file)
        module_name = dir |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join()
        ["DodoRouterWeb.#{module_name}Html"]

      true ->
        []
    end
  end)

modules =
  (ex_modules ++ heex_modules)
  |> Enum.sort()
  |> Enum.uniq()

# Detect GenServers/Agents (need {update, ...} instead of {load_module, ...})
{genserver_modules, regular_modules} =
  modules
  |> Enum.split_with(fn mod ->
    # Find the file for this module and check if it uses GenServer or Agent
    file = "lib/#{mod |> String.replace(".", "/") |> Macro.underscore()}.ex"
    case File.read(file) do
      {:ok, content} -> String.contains?(content, "use GenServer") or String.contains?(content, "use Agent")
      _ -> false
    end
  end)

instructions =
  Enum.map(regular_modules, fn mod -> "      {:load_module, #{mod}}" end) ++
  Enum.map(genserver_modules, fn mod -> "      {:update, #{mod}, {:advanced, []}}" end)

instructions_str = instructions |> Enum.join(",\n")

appup = """
# Auto-generated appup for #{new_vsn} <- #{old_vsn}
# Run: mix appup.generate #{old_vsn} #{new_vsn}

{
  ~c"#{new_vsn}",
  [
    {~c"#{old_vsn}", [
#{instructions_str}
    ]}
  ],
  [
    {~c"#{old_vsn}", [
#{instructions_str}
    ]}
  ]
}
"""

IO.puts(appup)
