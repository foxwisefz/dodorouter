#!/usr/bin/env elixir
# Auto-generates appup.ex from git diff between versions
# Usage: mix appup.generate 0.1.65 0.1.66

[old_vsn, new_vsn | _] = System.argv()

# Try tags first, fall back to the current checkout for the not-yet-tagged version
has_old_tag = System.cmd("git", ["tag", "-l", "v#{old_vsn}"]) |> elem(0) |> String.trim() != ""
has_new_tag = System.cmd("git", ["tag", "-l", "v#{new_vsn}"]) |> elem(0) |> String.trim() != ""

range =
  cond do
    has_old_tag and has_new_tag -> "v#{old_vsn}..v#{new_vsn}"
    has_old_tag -> "v#{old_vsn}..HEAD"
    has_new_tag -> "HEAD..v#{new_vsn}"
    true -> "HEAD"
  end

# Get changed files between versions
{output, 0} = System.cmd("git", ["diff", "--name-only", range, "--", "lib/"])

{added_output, 0} =
  System.cmd("git", ["diff", "--diff-filter=A", "--name-only", range, "--", "lib/"])

changed_files = String.split(output, "\n")
added_files = String.split(added_output, "\n") |> MapSet.new()

# Extract modules from .ex files, keeping file content for stateful classification
{ex_modules, module_contents} =
  changed_files
  |> Enum.filter(&String.ends_with?(&1, ".ex"))
  |> Enum.flat_map_reduce(%{}, fn file, acc ->
    case File.read(file) do
      {:ok, content} ->
        mods =
          Regex.scan(~r/^defmodule\s+([A-Za-z0-9._]+)\s+do/m, content)
          |> Enum.map(fn [_, mod] -> {mod, MapSet.member?(added_files, file)} end)

        new_acc =
          Enum.reduce(mods, acc, fn {mod, _}, a -> Map.put(a, mod, content) end)

        {mods, new_acc}

      _ ->
        {[], acc}
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

      # Controller templates: controllers/billing_html/show.html.heex compiles
      # into the module defined in controllers/billing_html.ex — read the real
      # name from that file's defmodule line. Guessing it by capitalizing path
      # segments produced DodoRouterWeb.BillingHtml for a module Phoenix names
      # DodoRouterWeb.BillingHTML; systools:make_relup then failed the whole
      # relup with {:no_such_module, ...} and v0.1.129 shipped without one
      # (dodo_router-5kk).
      Regex.match?(~r|controllers/(.+)_html/|, file) ->
        [[_, parent]] = Regex.scan(~r|^(.*controllers/.+_html)/|, file)
        ex_file = parent <> ".ex"

        case File.read(ex_file) do
          {:ok, content} ->
            Regex.scan(~r/^defmodule\s+([A-Za-z0-9._]+)\s+do/m, content)
            |> Enum.map(fn [_, mod] -> mod end)

          _ ->
            # Parent module file unreadable (e.g. deleted): fall back to the
            # path-derived guess rather than dropping the template silently.
            [[_, dir]] = Regex.scan(~r|controllers/(.+)_html/|, file)

            module_name =
              dir |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join()

            ["DodoRouterWeb.#{module_name}Html"]
        end

      true ->
        []
    end
  end)

modules =
  (ex_modules ++ heex_modules)
  |> Enum.map(fn
    {mod, added} when is_boolean(added) -> {mod, added}
    mod -> {mod, false}
  end)
  # One entry per module name. A new controller whose templates also changed
  # yields the same module twice — {mod, true} from the added .ex and
  # {mod, false} from the .heex — and tuple-level uniq kept both, emitting
  # add_module AND load_module for one module. added wins: the module is new.
  |> Enum.group_by(fn {mod, _added} -> mod end, fn {_mod, added} -> added end)
  |> Enum.map(fn {mod, addeds} -> {mod, Enum.any?(addeds)} end)
  |> Enum.sort()

# Categorize: new modules need add_module, changed need load_module/update
# For stateful modules (GenServer, Agent, LiveView), use {update, ..., {advanced, []}}
# so running processes get code_change/3 and pick up new code.
# For stateless modules, {load_module} is sufficient.
{genserver_modules, regular_modules} =
  modules
  |> Enum.split_with(fn {mod, _added} ->
    case Map.get(module_contents, mod) do
      nil ->
        false

      content ->
        String.contains?(content, "use GenServer") or
          String.contains?(content, "use Agent") or
          String.contains?(content, ":live_view")
    end
  end)

instructions =
  Enum.map(regular_modules, fn {mod, added} ->
    if added do
      "      {:add_module, #{mod}}"
    else
      "      {:load_module, #{mod}}"
    end
  end) ++
    Enum.map(genserver_modules, fn {mod, added} ->
      if added do
        "      {:add_module, #{mod}}"
      else
        "      {:update, #{mod}, {:advanced, []}}"
      end
    end)

# Downgrade instructions: reverse of upgrade
# add_module -> delete_module, delete_module -> add_module, load_module stays, update stays
downgrade_instructions =
  Enum.map(regular_modules, fn {mod, added} ->
    if added do
      "      {:delete_module, #{mod}}"
    else
      "      {:load_module, #{mod}}"
    end
  end) ++
    Enum.map(genserver_modules, fn {mod, added} ->
      if added do
        "      {:delete_module, #{mod}}"
      else
        "      {:update, #{mod}, {:advanced, []}}"
      end
    end)

instructions_str = instructions |> Enum.join(",\n")
downgrade_instructions_str = downgrade_instructions |> Enum.join(",\n")

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
#{downgrade_instructions_str}
    ]}
  ]
}
"""

IO.puts(appup)
