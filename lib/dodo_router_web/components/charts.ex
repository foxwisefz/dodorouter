defmodule DodoRouterWeb.Components.Charts do
  @moduledoc """
  Server-rendered dashboard chart components.

  Marks are HTML/SVG styled with the `--viz-*` palette defined in `app.css`
  (a CVD-validated categorical set — slots are assigned in fixed order via
  `series_color/1` and never cycled past 8; overflow folds into "Other").

  Hover tooltips are driven by the `VizTooltip` JS hook: any element with a
  `data-viz-tip` JSON payload gets a floating tooltip; charts that set
  `data-viz-crosshair` also get a vertical hairline snapped to the hovered
  bucket. Tooltips enhance but never gate — every chart has direct labels,
  axis ticks, or a table twin carrying the same values.
  """

  use Phoenix.Component

  @doc "Categorical series color for slot `idx` (0-based). Slots past 8 fold into Other."
  def series_color(idx) when idx in 0..7, do: "var(--viz-#{idx + 1})"
  def series_color(_idx), do: "var(--viz-other)"

  @doc """
  KPI stat tile: label, compact value, optional subtext and 12-point sparkline
  (de-emphasis stroke, accent end-dot on the current period).

  `:delta` is an optional period-over-period comparison, e.g.
  `%{text: "+12% vs prev 24h", direction: :up, polarity: :good}`. `direction`
  (`:up` | `:down` | `:flat`) picks the arrow glyph; `polarity`
  (`:good` | `:bad` | `:neutral`) picks the color — up isn't always good
  (spend up is a warning, success rate up is positive), so callers decide
  polarity per metric rather than the component assuming "up = green".
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :subtext, :string, default: nil
  attr :value_class, :string, default: "text-base-content"
  attr :spark, :list, default: nil
  attr :delta, :map, default: nil

  def stat_tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-base-300/50 bg-base-100 p-3 relative">
      <p class="text-xs font-medium text-base-content/50">{@label}</p>
      <p class={["mt-0.5 text-lg font-semibold", @value_class]}>{@value}</p>
      <p :if={@subtext} class="mt-0.5 text-xs text-base-content/40 truncate">{@subtext}</p>
      <p
        :if={@delta}
        data-kpi-delta={@delta.text}
        class={["mt-0.5 text-xs truncate", delta_color(@delta[:polarity])]}
      >
        {delta_arrow(@delta[:direction])} {@delta.text}
      </p>
      <div :if={spark_visible?(@spark)} class="absolute right-3 top-3 h-7 w-16">
        <svg viewBox="0 0 100 100" preserveAspectRatio="none" class="h-full w-full overflow-visible">
          <path
            d={spark_path(@spark)}
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            vector-effect="non-scaling-stroke"
            class="text-base-content/25"
          />
        </svg>
        <div
          class="absolute h-1.5 w-1.5 -translate-y-1/2 translate-x-1/2 rounded-full bg-accent ring-2 ring-base-100"
          style={spark_dot_style(@spark)}
        >
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Stacked column chart. `series` is a list of `%{name, color, values}` where
  every `values` list matches `labels` in length. Columns grow from a shared
  baseline, segments are separated by a 2px surface gap, and the whole bucket
  slot is the hover/focus hit target.
  """
  attr :id, :string, required: true
  attr :labels, :list, required: true, doc: "x label per bucket (already formatted)"
  attr :series, :list, required: true
  attr :unit, :atom, default: :count, values: [:count, :usd, :ms]
  attr :height, :integer, default: 190
  attr :empty_label, :string, default: "No requests in this range"

  def column_chart(assigns) do
    totals = column_totals(assigns.series, length(assigns.labels))
    max = nice_ceil(Enum.max(totals, fn -> 0 end))

    assigns =
      assigns
      |> assign(:totals, totals)
      |> assign(:max, max)
      |> assign(:ticks, ticks(max, assigns.unit))
      |> assign(:empty?, Enum.all?(totals, &(&1 == 0)))
      |> assign(:label_idxs, label_indices(length(assigns.labels)))

    ~H"""
    <div id={@id} phx-hook="VizTooltip">
      <div class="flex">
        <div class="relative w-10 shrink-0" style={"height: #{@height}px"}>
          <span
            :for={{pct, label} <- @ticks}
            class="absolute right-1 -translate-y-1/2 text-[10px] tabular-nums text-base-content/40"
            style={"top: #{100 - pct}%"}
          >
            {label}
          </span>
        </div>
        <div class="relative flex-1" style={"height: #{@height}px"}>
          <div
            :for={{pct, _label} <- @ticks}
            class="absolute inset-x-0 h-px"
            style={"top: #{100 - pct}%; background: #{if pct == 0, do: "var(--viz-axis)", else: "var(--viz-grid)"}"}
          >
          </div>
          <p
            :if={@empty?}
            class="absolute inset-0 flex items-center justify-center text-xs text-base-content/40"
          >
            {@empty_label}
          </p>
          <div class="absolute inset-0 flex items-stretch">
            <div
              :for={{label, idx} <- Enum.with_index(@labels)}
              class="viz-slot relative flex-1 min-w-0 cursor-default"
              tabindex={if Enum.at(@totals, idx) > 0, do: "0"}
              data-viz-tip={column_tip(label, @series, idx, @unit)}
            >
              <div class="absolute inset-x-0.5 bottom-0 top-0 flex justify-center">
                <div class="flex w-full max-w-6 flex-col justify-end gap-[2px] h-full">
                  <%= for {seg, seg_idx} <- Enum.with_index(visible_segments(@series, idx, @max)) do %>
                    <div
                      class={["viz-seg w-full shrink-0", seg_idx == 0 && "rounded-t"]}
                      style={"height: max(#{seg.pct}%, 2px); background: #{seg.color}"}
                    >
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      <div class="flex">
        <div class="w-10 shrink-0"></div>
        <div class="relative h-5 flex-1">
          <span
            :for={idx <- @label_idxs}
            class="absolute top-1 -translate-x-1/2 whitespace-nowrap text-[10px] text-base-content/40"
            style={"left: #{(idx + 0.5) / max(length(@labels), 1) * 100}%"}
          >
            {Enum.at(@labels, idx)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Multi-series line chart with nil gaps (a missing bucket breaks the line
  rather than faking a zero). Crosshair + tooltip via the VizTooltip hook.
  """
  attr :id, :string, required: true
  attr :labels, :list, required: true
  attr :series, :list, required: true, doc: "%{name, color, values} — values may contain nils"
  attr :unit, :atom, default: :ms
  attr :height, :integer, default: 170
  attr :empty_label, :string, default: "No data in this range"

  def line_chart(assigns) do
    max =
      assigns.series
      |> Enum.flat_map(& &1.values)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)
      |> nice_ceil()

    assigns =
      assigns
      |> assign(:max, max)
      |> assign(:ticks, ticks(max, assigns.unit))
      |> assign(:empty?, Enum.all?(assigns.series, fn s -> Enum.all?(s.values, &is_nil/1) end))
      |> assign(:label_idxs, label_indices(length(assigns.labels)))

    ~H"""
    <div id={@id} phx-hook="VizTooltip" data-viz-crosshair>
      <div class="flex">
        <div class="relative w-10 shrink-0" style={"height: #{@height}px"}>
          <span
            :for={{pct, label} <- @ticks}
            class="absolute right-1 -translate-y-1/2 text-[10px] tabular-nums text-base-content/40"
            style={"top: #{100 - pct}%"}
          >
            {label}
          </span>
        </div>
        <div class="relative flex-1" style={"height: #{@height}px"}>
          <div
            :for={{pct, _label} <- @ticks}
            class="absolute inset-x-0 h-px"
            style={"top: #{100 - pct}%; background: #{if pct == 0, do: "var(--viz-axis)", else: "var(--viz-grid)"}"}
          >
          </div>
          <p
            :if={@empty?}
            class="absolute inset-0 flex items-center justify-center text-xs text-base-content/40"
          >
            {@empty_label}
          </p>
          <div
            class="viz-crosshair pointer-events-none absolute bottom-0 top-0 hidden w-px"
            style="background: var(--viz-axis)"
          >
          </div>
          <svg
            viewBox="0 0 100 100"
            preserveAspectRatio="none"
            class="absolute inset-0 h-full w-full overflow-visible"
          >
            <path
              :for={s <- @series}
              d={line_path(s.values, @max)}
              fill="none"
              stroke={s.color}
              stroke-width="2"
              stroke-linejoin="round"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
            />
          </svg>
          <%!-- Isolated points (both neighbors nil) have no line run — mark them
                with a dot so a lone bucket of data stays visible. --%>
          <div
            :for={{x, y, color} <- isolated_points(@series, @max)}
            class="absolute h-2 w-2 -translate-x-1/2 -translate-y-1/2 rounded-full ring-2 ring-base-100"
            style={"left: #{x}%; top: #{y}%; background: #{color}"}
          >
          </div>
          <div class="absolute inset-0 flex items-stretch">
            <div
              :for={{label, idx} <- Enum.with_index(@labels)}
              class="relative flex-1 min-w-0 cursor-default"
              tabindex={if line_bucket_has_data?(@series, idx), do: "0"}
              data-viz-tip={line_tip(label, @series, idx, @unit)}
              data-viz-x
            >
            </div>
          </div>
        </div>
      </div>
      <div class="flex">
        <div class="w-10 shrink-0"></div>
        <div class="relative h-5 flex-1">
          <span
            :for={idx <- @label_idxs}
            class="absolute top-1 -translate-x-1/2 whitespace-nowrap text-[10px] text-base-content/40"
            style={"left: #{(idx + 0.5) / max(length(@labels), 1) * 100}%"}
          >
            {Enum.at(@labels, idx)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Horizontal bar list (nominal categories, single hue): name, bar, value at
  the bar end. Rows past 8 should be folded into "Other" by the caller.
  """
  attr :id, :string, required: true

  attr :rows, :list,
    required: true,
    doc: "%{name, value, display, subtext (optional), color (optional)}"

  attr :empty_label, :string, default: "No data in this range"

  def hbar_list(assigns) do
    max = assigns.rows |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, :max, max)

    ~H"""
    <div id={@id} class="space-y-2.5" phx-hook="VizTooltip">
      <p :if={@rows == []} class="py-6 text-center text-xs text-base-content/40">
        {@empty_label}
      </p>
      <div
        :for={row <- @rows}
        class="viz-row cursor-default"
        tabindex="0"
        data-viz-tip={hbar_tip(row)}
      >
        <div class="mb-1 flex items-baseline justify-between gap-2">
          <span class="truncate text-xs font-medium text-base-content/70">{row.name}</span>
          <span class="shrink-0 text-xs font-semibold tabular-nums text-base-content">
            {row.display}
          </span>
        </div>
        <div class="h-2 overflow-hidden rounded-full bg-base-200">
          <div
            class="viz-seg h-full rounded-full"
            style={"width: #{hbar_pct(row.value, @max)}%; background: #{Map.get(row, :color) || series_color(0)}"}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Part-to-whole share bar: one horizontal 100% bar with 2px surface gaps.
  Identity is carried by the legend/table the caller renders alongside.
  """
  attr :id, :string, required: true

  attr :segments, :list,
    required: true,
    doc: "%{name, value, display, color, key (optional, for data-timing-segment/test hooks)}"

  attr :tip_suffix, :string,
    default: "of spend",
    doc: "trailing words in the hover tooltip, e.g. \"of spend\" or \"of total time\""

  def share_bar(assigns) do
    total = assigns.segments |> Enum.map(& &1.value) |> Enum.sum()
    assigns = assign(assigns, :total, total)

    ~H"""
    <div id={@id} phx-hook="VizTooltip">
      <div :if={@total > 0} class="flex h-3 w-full gap-[2px] overflow-hidden rounded-full">
        <div
          :for={seg <- @segments}
          :if={seg.value > 0}
          class="viz-slot h-full min-w-[3px]"
          tabindex="0"
          data-viz-tip={share_tip(seg, @total, @tip_suffix)}
          data-timing-segment={Map.get(seg, :key)}
          style={"flex-grow: #{seg.value}; flex-basis: 0"}
        >
          <div class="viz-seg h-full w-full" style={"background: #{seg.color}"}></div>
        </div>
      </div>
      <div :if={@total == 0} class="h-3 w-full rounded-full bg-base-200"></div>
    </div>
    """
  end

  @doc "Legend: swatch + name per series. Always rendered for ≥ 2 series."
  attr :series, :list, required: true, doc: "%{name, color}"
  attr :kind, :atom, default: :rect, values: [:rect, :line]

  def legend(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
      <span :for={s <- @series} class="flex items-center gap-1.5 text-xs text-base-content/60">
        <span
          :if={@kind == :rect}
          class="h-2.5 w-2.5 rounded-sm"
          style={"background: #{s.color}"}
        >
        </span>
        <span :if={@kind == :line} class="h-0.5 w-3.5 rounded-full" style={"background: #{s.color}"}>
        </span>
        {s.name}
      </span>
    </div>
    """
  end

  # ---- formatting helpers (public: the dashboard reuses them) ----

  @doc """
  Human name for `request_logs.call_type`.

  One function because there were three: the logs list said "Chat", the detail
  sidebar said "Completion", and the session view said "chat" — three names for
  one stored value, which reads as three different things rather than one.
  """
  def call_type_name("tool_call"), do: "Tool call"
  def call_type_name("tool_enabled_completion"), do: "Chat + tools"
  def call_type_name("completion"), do: "Chat"
  def call_type_name(nil), do: "Chat"
  def call_type_name(other), do: other

  def format_usd(nil), do: "$0"
  def format_usd(%Decimal{} = d), do: d |> Decimal.to_float() |> format_usd()
  def format_usd(+0.0), do: "$0"
  def format_usd(v) when v >= 1000, do: "$#{format_compact(v)}"
  def format_usd(v) when v >= 1, do: "$#{:erlang.float_to_binary(v / 1, decimals: 2)}"
  def format_usd(v) when v >= 0.01, do: "$#{:erlang.float_to_binary(v / 1, decimals: 3)}"
  def format_usd(v) when v > 0, do: "$#{significant(v, 2)}"
  def format_usd(v) when is_integer(v), do: format_usd(v / 1)

  def format_compact(nil), do: "0"
  def format_compact(%Decimal{} = d), do: d |> Decimal.to_float() |> format_compact()

  def format_compact(v) when v >= 1_000_000,
    do: "#{Float.round(v / 1_000_000, 1) |> trim_zero()}M"

  def format_compact(v) when v >= 1_000, do: "#{Float.round(v / 1_000, 1) |> trim_zero()}K"
  def format_compact(v) when is_float(v), do: trim_zero(Float.round(v, 1))
  def format_compact(v), do: to_string(v)

  def format_ms(nil), do: "-"
  def format_ms(%Decimal{} = d), do: format_ms(Decimal.to_float(d))
  def format_ms(v) when v >= 10_000, do: "#{Float.round(v / 1000, 1) |> trim_zero()}s"
  def format_ms(v), do: "#{round(v)}ms"

  def format_unit(v, :usd), do: format_usd(v)
  def format_unit(v, :count), do: format_compact(v)
  def format_unit(v, :ms), do: format_ms(v)

  # ---- internals ----

  defp delta_arrow(:up), do: "▲"
  defp delta_arrow(:down), do: "▼"
  defp delta_arrow(_), do: "•"

  defp delta_color(:good), do: "text-success"
  defp delta_color(:bad), do: "text-warning"
  defp delta_color(_), do: "text-base-content/40"

  defp spark_visible?(nil), do: false

  defp spark_visible?(values) when is_list(values) do
    length(values) >= 2 and Enum.max(values, fn -> 0 end) > 0
  end

  defp spark_max(values), do: values |> Enum.max(fn -> 1 end) |> max(1)

  defp spark_path(values) do
    n = length(values)
    max = spark_max(values)

    values
    |> Enum.with_index()
    |> Enum.map(fn {v, idx} ->
      x = Float.round(idx / max(n - 1, 1) * 100, 1)
      y = Float.round(100 - v / max * 88 - 6, 1)
      "#{if idx == 0, do: "M", else: "L"}#{x},#{y}"
    end)
    |> Enum.join(" ")
  end

  defp spark_dot_style(values) do
    max = spark_max(values)
    last = List.last(values) || 0
    "left: 100%; top: #{Float.round(100 - last / max * 88 - 6, 1)}%"
  end

  defp trim_zero(f) do
    s = to_string(f)
    if String.ends_with?(s, ".0"), do: String.slice(s, 0..-3//1), else: s
  end

  defp significant(v, digits) do
    exp = v |> :math.log10() |> :math.floor()
    decimals = max(digits - 1 - trunc(exp), 0)
    :erlang.float_to_binary(v / 1, decimals: decimals)
  end

  defp column_totals(series, n) do
    for idx <- 0..max(n - 1, 0)//1 do
      series |> Enum.map(&(Enum.at(&1.values, idx) || 0)) |> Enum.sum()
    end
  end

  defp visible_segments(series, idx, max) do
    # Topmost segment first (flex-col justify-end): reverse the series order
    # so series 1 sits on the baseline.
    series
    |> Enum.map(fn s -> %{color: s.color, value: Enum.at(s.values, idx) || 0} end)
    |> Enum.reject(&(&1.value <= 0))
    |> Enum.reverse()
    |> Enum.map(fn seg -> Map.put(seg, :pct, Float.round(seg.value / max * 100, 2)) end)
  end

  defp line_path(values, max) do
    n = length(values)

    values
    |> Enum.with_index()
    |> Enum.chunk_by(fn {v, _} -> is_nil(v) end)
    |> Enum.reject(fn [{v, _} | _] -> is_nil(v) end)
    |> Enum.map(fn run ->
      run
      |> Enum.with_index()
      |> Enum.map(fn {{v, idx}, run_idx} ->
        x = Float.round((idx + 0.5) / max(n, 1) * 100, 2)
        y = Float.round(100 - v / max * 100, 2)
        "#{if run_idx == 0, do: "M", else: "L"}#{x},#{y}"
      end)
      |> Enum.join(" ")
    end)
    |> Enum.join(" ")
  end

  defp isolated_points(series, max) do
    for s <- series,
        {v, idx} <- Enum.with_index(s.values),
        not is_nil(v),
        is_nil(value_at(s.values, idx - 1)),
        is_nil(value_at(s.values, idx + 1)) do
      n = length(s.values)
      x = Float.round((idx + 0.5) / max(n, 1) * 100, 2)
      y = Float.round(100 - v / max * 100, 2)
      {x, y, s.color}
    end
  end

  # Enum.at(list, -1) wraps to the tail — a negative index means "no left
  # neighbor", never the last element.
  defp value_at(_values, idx) when idx < 0, do: nil
  defp value_at(values, idx), do: Enum.at(values, idx)

  defp line_bucket_has_data?(series, idx) do
    Enum.any?(series, fn s -> not is_nil(Enum.at(s.values, idx)) end)
  end

  defp hbar_pct(_value, max) when max <= 0, do: 0
  defp hbar_pct(value, max), do: Float.round(value / max * 100, 2)

  defp nice_ceil(v) when v <= 0, do: 1

  defp nice_ceil(v) do
    exp = v |> :math.log10() |> :math.floor()
    base = :math.pow(10, exp)
    frac = v / base

    mult =
      cond do
        frac <= 1.0 -> 1.0
        frac <= 2.0 -> 2.0
        frac <= 2.5 -> 2.5
        frac <= 5.0 -> 5.0
        true -> 10.0
      end

    mult * base
  end

  defp ticks(max, unit) do
    for pct <- [0, 25, 50, 75, 100] do
      {pct, format_unit(max * pct / 100, unit)}
    end
  end

  defp label_indices(n) when n <= 0, do: []
  defp label_indices(n) when n <= 7, do: Enum.to_list(0..(n - 1))

  defp label_indices(n) do
    stride = ceil(n / 6)
    Enum.take_every(0..(n - stride), stride)
  end

  defp column_tip(label, series, idx, unit) do
    rows =
      series
      |> Enum.map(fn s -> {s.name, Enum.at(s.values, idx) || 0, s.color} end)
      |> Enum.reject(fn {_, v, _} -> v <= 0 end)
      |> Enum.map(fn {name, v, color} ->
        %{label: name, value: format_unit(v, unit), color: color}
      end)

    total = series |> Enum.map(&(Enum.at(&1.values, idx) || 0)) |> Enum.sum()

    rows =
      cond do
        rows == [] ->
          [%{label: "No traffic", value: "", color: nil}]

        length(rows) > 1 ->
          rows ++ [%{label: "Total", value: format_unit(total, unit), color: nil}]

        true ->
          rows
      end

    Jason.encode!(%{title: label, rows: rows})
  end

  defp line_tip(label, series, idx, unit) do
    rows =
      for s <- series, v = Enum.at(s.values, idx), not is_nil(v) do
        %{label: s.name, value: format_unit(v, unit), color: s.color}
      end

    rows = if rows == [], do: [%{label: "No traffic", value: "", color: nil}], else: rows
    Jason.encode!(%{title: label, rows: rows})
  end

  defp hbar_tip(row) do
    rows = [
      %{label: row.name, value: row.display, color: Map.get(row, :color) || series_color(0)}
    ]

    rows =
      case Map.get(row, :subtext) do
        nil -> rows
        sub -> rows ++ [%{label: sub, value: "", color: nil}]
      end

    Jason.encode!(%{title: row.name, rows: rows})
  end

  defp share_tip(seg, total, suffix) do
    pct = Float.round(seg.value / total * 100, 1)

    Jason.encode!(%{
      title: seg.name,
      rows: [%{label: "#{pct}% #{suffix}", value: seg.display, color: seg.color}]
    })
  end
end
