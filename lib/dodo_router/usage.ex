defmodule DodoRouter.Usage do
  @moduledoc """
  Helpers for interpreting the token-usage numbers stored on request logs.

  Providers disagree on whether `prompt_tokens` already includes the tokens
  that were served from (or written to) cache, and the stored usage keeps each
  provider's own convention:

    * OpenAI-family (`prompt_tokens_details.cached_tokens`) — `prompt_tokens`
      is the *total* input, cache reads included.
    * Anthropic (`cache_read_input_tokens` / `cache_creation_input_tokens`) —
      `prompt_tokens` maps to `input_tokens`, which counts only the input that
      was neither read from nor written to cache.

  No column records which convention a row used, so the shape of the numbers
  decides: cache tokens that exceed `prompt_tokens` can only come from a
  provider that reports them separately. Getting this wrong is what turned a
  38,356-token cache hit over a 260-token billed prompt into "14752%".
  """

  @doc """
  Total input tokens for a request, cache reads and writes included.
  """
  @spec total_input_tokens(integer | nil, integer | nil, integer | nil) :: non_neg_integer
  def total_input_tokens(prompt, cached, written \\ 0) do
    {prompt, cached, written} = normalize(prompt, cached, written)

    if cache_excluded?(prompt, cached, written) do
      prompt + cached + written
    else
      prompt
    end
  end

  @doc """
  Input tokens that were neither read from nor written to cache — the ones
  billed at the full input rate.
  """
  @spec new_input_tokens(integer | nil, integer | nil, integer | nil) :: non_neg_integer
  def new_input_tokens(prompt, cached, written \\ 0) do
    {prompt, cached, written} = normalize(prompt, cached, written)

    if cache_excluded?(prompt, cached, written) do
      prompt
    else
      max(0, prompt - cached - written)
    end
  end

  @doc """
  Share of a request's input tokens that were served from cache, as a
  percentage. `precision` is passed to `Float.round/2`.

  Returns `nil` when there is no input to divide by.
  """
  @spec cache_hit_pct(integer | nil, integer | nil, integer | nil, non_neg_integer) ::
          float | nil
  def cache_hit_pct(prompt, cached, written \\ 0, precision \\ 1) do
    total = total_input_tokens(prompt, cached, written)

    if total > 0 do
      Float.round((cached || 0) / total * 100, precision)
    end
  end

  # Anthropic-style: the cache figures don't fit inside prompt_tokens, so
  # prompt_tokens must be reporting new input only.
  defp cache_excluded?(prompt, cached, written), do: cached + written > prompt

  defp normalize(prompt, cached, written), do: {prompt || 0, cached || 0, written || 0}
end
