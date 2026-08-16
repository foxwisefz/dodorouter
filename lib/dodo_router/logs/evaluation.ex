defmodule DodoRouter.Logs.Evaluation do
  @moduledoc """
  Schema for storing evaluations of request logs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "evaluations" do
    field :name, :string
    field :criteria, :string
    field :good_examples, :string
    field :bad_examples, :string
    field :judge_model, :string
    field :candidate_targets, {:array, :map}, default: []
    # The set of source logs a multi-log evaluation replays; empty means
    # just the anchor. request_log_id stays required as the anchor
    # (= first of the set), so every router-scoping join keeps working.
    field :source_log_ids, {:array, :binary_id}, default: []
    # Prompt variants: [%{"name" => ..., "system_prompt" => ...}]. Empty
    # means one implicit as-served baseline. A nil system_prompt inside a
    # variant means "as served", so a baseline can sit in the comparison
    # under its own name. jsonb keeps room for richer patches later.
    field :prompt_variants, {:array, :map}, default: []
    field :repetitions, :integer, default: 3
    field :benchmark_status, :string, default: "draft"
    # Batch written by the most recent benchmark execution; aggregates are
    # scoped to it. Set programmatically, never cast from params.
    field :last_batch_id, :binary_id
    field :run_count, :integer, virtual: true, default: 0
    # Compatibility with databases created from the earlier unused schema.
    field :rating_type, :string, default: "good"

    belongs_to :request_log, DodoRouter.Logs.RequestLog
    belongs_to :evaluated_by, DodoRouter.Accounts.User
    belongs_to :judge_provider_key, DodoRouter.Providers.ProviderKey
    has_many :runs, DodoRouter.Logs.EvaluationRun

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for an evaluation.
  """
  def changeset(evaluation, attrs) do
    evaluation
    |> cast(attrs, [
      :name,
      :criteria,
      :good_examples,
      :bad_examples,
      :judge_model,
      :candidate_targets,
      :source_log_ids,
      :prompt_variants,
      :repetitions,
      :judge_provider_key_id,
      :request_log_id,
      :evaluated_by_id
    ])
    |> validate_required([
      :name,
      :criteria,
      :judge_model,
      :judge_provider_key_id,
      :request_log_id,
      :evaluated_by_id
    ])
    |> validate_length(:name, max: 120)
    |> validate_length(:criteria, max: 10_000)
    |> validate_number(:repetitions, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_length(:candidate_targets, min: 1, max: 30)
    |> validate_length(:source_log_ids, max: 20)
    |> validate_length(:prompt_variants, max: 10)
    |> validate_prompt_variant_shape()
    |> validate_candidate_target_shape()
    |> foreign_key_constraint(:request_log_id)
    |> foreign_key_constraint(:evaluated_by_id)
    |> foreign_key_constraint(:judge_provider_key_id)
  end

  @doc """
  The full set of source logs this evaluation replays. Rows from before
  multi-log evaluations (or created single-log) read as just the anchor.
  """
  def source_log_ids(%__MODULE__{source_log_ids: ids, request_log_id: anchor}) do
    case ids do
      ids when is_list(ids) and ids != [] -> ids
      _ -> [anchor]
    end
  end

  @doc """
  The prompt variants this evaluation fans out over. Empty reads as one
  implicit as-served baseline (`nil`), which is exactly how every
  pre-variant evaluation behaves.
  """
  def prompt_variants(%__MODULE__{prompt_variants: variants}) do
    case variants do
      variants when is_list(variants) and variants != [] -> variants
      _ -> [nil]
    end
  end

  # Two variants with one name would collapse into one ranking row and make
  # the retry unable to recover the right patch.
  defp validate_prompt_variant_shape(changeset) do
    variants = get_field(changeset, :prompt_variants) || []

    names = Enum.map(variants, &(is_map(&1) && &1["name"]))

    cond do
      variants == [] ->
        changeset

      Enum.any?(names, &(!is_binary(&1) or String.trim(&1) == "")) ->
        add_error(changeset, :prompt_variants, "every variant needs a non-empty name")

      length(Enum.uniq(names)) != length(names) ->
        add_error(changeset, :prompt_variants, "variant names must be distinct")

      Enum.any?(
        variants,
        &(not (is_nil(&1["system_prompt"]) or is_binary(&1["system_prompt"])))
      ) ->
        add_error(changeset, :prompt_variants, "system_prompt must be a string or null")

      true ->
        changeset
    end
  end

  defp validate_candidate_target_shape(changeset) do
    validate_change(changeset, :candidate_targets, fn :candidate_targets, targets ->
      valid? =
        Enum.all?(targets, fn
          %{} = target ->
            Enum.all?(
              ~w(provider_key_id provider model),
              &(is_binary(target[&1]) and target[&1] != "")
            )

          _other ->
            false
        end)

      if valid?,
        do: [],
        else: [candidate_targets: "entries must include provider_key_id, provider, and model"]
    end)
  end
end
