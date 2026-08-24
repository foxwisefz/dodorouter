defmodule DodoRouter.Agents.Scopes do
  @moduledoc """
  What an agent credential is allowed to do.

  The split that matters is `logs:read` versus `logs:read_bodies`. Everything
  else on this surface is metadata — models, token counts, cost, latency —
  and an agent comparing price against quality needs all of it. The prompt
  and response text is a different kind of data: it is the product's actual
  traffic, and a credential that can rank models does not need to read it.

  Redaction was considered for that job and rejected: in an LLM proxy the
  sensitive content *is* the prompt, which no pattern identifies, and
  mangling it would break the replay fidelity the evaluations depend on.
  A scope answers "who may read this" honestly; a regex only pretends to.
  """

  @scopes [
    %{
      name: "logs:read",
      label: "Read request metadata",
      description:
        "Models, token counts, cost, latency and status for this router's requests. No prompt or response text.",
      sensitive?: false
    },
    %{
      name: "logs:read_bodies",
      label: "Read prompts and responses",
      description:
        "The stored request and response text itself. Everything the product sent and received.",
      sensitive?: true
    },
    %{
      name: "evals:read",
      label: "Read evaluations",
      description: "Evaluation setups, scores, rankings and judge feedback.",
      sensitive?: false
    },
    %{
      name: "evals:write",
      label: "Create and run evaluations",
      description:
        "Create evaluations and start benchmarks. Running a benchmark calls providers and spends money.",
      sensitive?: true
    }
  ]

  @names Enum.map(@scopes, & &1.name)

  # Per-router narrowing rides the same rail as the permission scopes: consent
  # appends one of these per selected router, the grant and every refresh
  # rotation carry them like any other scope, and `Principal.from_oauth` reads
  # them back. The id, not the slug, because a rename must not silently sever
  # a grant. No scope of this shape means the deliberate unbounded case —
  # every router the owner has, now and later (see `Principal`).
  @router_scope_prefix "router:"

  @doc "The scope that narrows a token to one router, by id."
  def router_scope(router_id) when is_binary(router_id), do: @router_scope_prefix <> router_id

  @doc "Whether this scope name is a per-router narrowing rather than a permission."
  def router_scope?(name) when is_binary(name),
    do: String.starts_with?(name, @router_scope_prefix)

  def router_scope?(_name), do: false

  @doc """
  The router ids a scope list narrows to. Empty means no narrowing was granted.

  Malformed ids are dropped rather than kept: downstream compares these against
  real router ids, so a mangled entry could never match anything anyway — the
  place that refuses them loudly is `AuthZ.ScopePolicy`, at grant time.
  """
  def router_ids(scopes) when is_list(scopes) do
    for @router_scope_prefix <> id <- scopes,
        match?({:ok, _}, Ecto.UUID.cast(id)),
        do: id
  end

  @doc "Every scope, in the order the UI should offer them."
  def all, do: @scopes

  @doc "Just the names, for validation."
  def names, do: @names

  @doc """
  The default a new token gets: everything except reading transcript text.

  Reading bodies is the one an operator should have to reach for deliberately,
  so it is never on by default — including when an agent asks for a token and
  a human clicks through the form quickly.
  """
  def defaults, do: @names -- ["logs:read_bodies"]

  def valid?(name), do: name in @names

  def sensitive?(name), do: Enum.any?(@scopes, &(&1.name == name and &1.sensitive?))

  def get(name), do: Enum.find(@scopes, &(&1.name == name))

  @doc """
  Whether `held` satisfies `required`.

  No hierarchy: `logs:read_bodies` does not imply `logs:read`. Implication
  would mean granting the sensitive scope silently widens the others, and the
  UI grants them explicitly anyway.
  """
  def satisfied?(held, required) when is_list(held) and is_binary(required),
    do: required in held

  def satisfied?(held, required) when is_list(held) and is_list(required),
    do: Enum.all?(required, &(&1 in held))
end
