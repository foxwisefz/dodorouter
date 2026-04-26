defmodule DodoRouter.Models do
  @moduledoc """
  Context for managing model capabilities and pricing.
  """

  import Ecto.Query
  alias DodoRouter.Repo
  alias DodoRouter.Models.Model

  def list_models do
    Repo.all(from m in Model, order_by: [asc: m.provider_slug, asc: m.model_id])
  end

  def list_models_by_provider(provider_slug) do
    Repo.all(from m in Model, where: m.provider_slug == ^provider_slug, order_by: m.model_id)
  end

  def get_model(id), do: Repo.get(Model, id)

  def get_model_by_id(provider_slug, model_id) do
    Repo.get_by(Model, provider_slug: provider_slug, model_id: model_id)
  end

  def get_model!(id), do: Repo.get!(Model, id)

  def create_model(attrs \\ %{}) do
    %Model{}
    |> Model.changeset(attrs)
    |> Repo.insert()
  end

  def update_model(%Model{} = model, attrs) do
    model
    |> Model.changeset(attrs)
    |> Repo.update()
  end

  def delete_model(%Model{} = model) do
    Repo.delete(model)
  end

  def upsert_model(attrs) do
    %Model{}
    |> Model.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:provider_slug, :model_id]
    )
  end

  @doc """
  Check if a model supports the required capabilities for an eval case.
  Returns {:ok, model} or {:error, :missing_capabilities, list}
  """
  def check_capabilities(%Model{} = model, required_capabilities) do
    missing =
      Enum.filter(required_capabilities, fn cap ->
        not Map.get(model, cap, false)
      end)

    case missing do
      [] -> {:ok, model}
      caps -> {:error, :missing_capabilities, caps}
    end
  end

  @doc """
  Filter models that support all given capabilities.
  """
  def filter_by_capabilities(capabilities) when is_list(capabilities) do
    base_query = from(m in Model)

    Enum.reduce(capabilities, base_query, fn cap, query ->
      case cap do
        :supports_vision -> from(m in query, where: m.supports_vision == true)
        :supports_audio_input -> from(m in query, where: m.supports_audio_input == true)
        :supports_audio_output -> from(m in query, where: m.supports_audio_output == true)
        :supports_function_calling -> from(m in query, where: m.supports_function_calling == true)
        :supports_streaming -> from(m in query, where: m.supports_streaming == true)
        :supports_system_messages -> from(m in query, where: m.supports_system_messages == true)
        :supports_response_schema -> from(m in query, where: m.supports_response_schema == true)
        :supports_reasoning -> from(m in query, where: m.supports_reasoning == true)
        :supports_prompt_caching -> from(m in query, where: m.supports_prompt_caching == true)
        _ -> query
      end
    end)
    |> Repo.all()
  end

  @doc """
  Calculate cost for a request given token counts.
  Returns cost in USD.
  """
  def calculate_cost(%Model{} = model, input_tokens, output_tokens) do
    input_cost =
      if model.input_price_per_million do
        Decimal.mult(model.input_price_per_million, Decimal.div(input_tokens, 1_000_000))
      else
        Decimal.new(0)
      end

    output_cost =
      if model.output_price_per_million do
        Decimal.mult(model.output_price_per_million, Decimal.div(output_tokens, 1_000_000))
      else
        Decimal.new(0)
      end

    Decimal.add(input_cost, output_cost)
  end
end
