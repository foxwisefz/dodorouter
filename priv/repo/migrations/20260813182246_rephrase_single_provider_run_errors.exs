defmodule DodoRouter.Repo.Migrations.RephraseSingleProviderRunErrors do
  use Ecto.Migration

  # An earlier repair in this series wrote "every provider failed (X: Y)"
  # for chains that only ever had one provider in them. Evaluations dispatch
  # with an explicit single step, so that phrasing described a fallback that
  # cannot occur — and implied the judge might have been served by something
  # other than the model the evaluation names, which is the one thing a
  # judge must never be.
  #
  # Only rows naming exactly one provider are rewritten; a genuine
  # multi-provider chain keeps its list.
  def up do
    execute """
    UPDATE evaluation_runs
    SET error = regexp_replace(error, 'every provider failed \\(([a-z0-9_-]+): (.+)\\)$', '\\1 \\2')
    WHERE error ~ 'every provider failed \\([a-z0-9_-]+: [^,;]+\\)$'
    """
  end

  def down, do: :ok
end
