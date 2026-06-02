#!/usr/bin/env elixir
# Auto-generates appup.ex from git diff between versions
# Usage: mix appup.generate 0.1.65 0.1.66

[old_vsn, new_vsn | _] = System.argv()

# Get changed .ex files between versions
{output, 0} = System.cmd("git", ["diff", "--name-only", "v#{old_vsn}..v#{new_vsn}", "--", "lib/"])

modules =
  output
  |> String.split("\n")
  |> Enum.filter(&String.ends_with?(&1, ".ex"))
  |> Enum.flat_map(fn file ->
    case File.read(file) do
      {:ok, content} ->
        Regex.scan(~r/^defmodule\s+([A-Za-z0-9._]+)\s+do/m, content)
        |> Enum.map(fn [_, mod] -> mod end)
      _ -> []
    end
  end)
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
  Enum.map(regular_modules, fn mod -> "      {load_module, #{mod}}" end) ++
  Enum.map(genserver_modules, fn mod -> "      {update, #{mod}, {advanced, []}}" end)

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
