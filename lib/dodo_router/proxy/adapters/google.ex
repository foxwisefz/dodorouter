defmodule DodoRouter.Proxy.Adapters.Google do
  @moduledoc """
  Adapter for Google Gemini API.

  Converts OpenAI format to Gemini format and back.
  """

  use DodoRouter.Proxy.Adapter.Registry,
    slug: "google",
    display_name: "Google",
    key_slugs: ["google"],
    endpoints: %{
      "google" => "https://generativelanguage.googleapis.com/v1beta"
    },
    models: ~w(gemini-2.0-flash gemini-2.5-pro gemini-2.5-flash gemini-1.5-pro gemini-1.5-flash),
    color: "blue",
    short_description: "Gemini 2.0, 2.5, 1.5 models"

  require Logger

  alias DodoRouter.Proxy.Adapter
  alias DodoRouter.Proxy.FinchTelemetry
  alias DodoRouter.Routers.RoutingStep

  @timeout_ms 120_000

  @impl true
  def call(request, %RoutingStep{} = step, api_key, _client_headers \\ []) do
    url =
      "https://generativelanguage.googleapis.com/v1beta/models/#{step.model}:generateContent?key=#{api_key}"

    body = build_gemini_request(request)

    headers = [{"Content-Type", "application/json"}]
    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()

    case Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: response_body, headers: resp_headers}} ->
        total_ms = latency(start_time)
        upload_ms = FinchTelemetry.get_upload_ms(start_time)

        meta = %{
          "ttfb_ms" => total_ms,
          "upload_ms" => upload_ms,
          "payload_size_bytes" => payload_size_bytes,
          "provider_processing_ms" => nil
        }

        response = convert_to_openai_format(response_body)
        {:ok, Map.put(response, "_meta", meta), %{headers: resp_headers}}

      {:ok, %{status: status, body: response_body, headers: resp_headers}} ->
        Logger.error("[Google] Non-200 response: status=#{status} body=#{inspect(response_body)}")
        reason = Adapter.categorize_error(status, response_body)

        {:error, reason,
         %{
           status: status,
           body: response_body,
           latency_ms: latency(start_time),
           headers: resp_headers
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  @impl true
  def stream(request, %RoutingStep{} = step, api_key, send_chunk, _client_headers \\ []) do
    url =
      "https://generativelanguage.googleapis.com/v1beta/models/#{step.model}:streamGenerateContent?key=#{api_key}&alt=sse"

    body = build_gemini_request(request)

    headers = [{"Content-Type", "application/json"}]
    payload_size_bytes = body |> Jason.encode!() |> byte_size()
    start_time = FinchTelemetry.mark_request_start()
    Process.delete(:__google_stream_acc__)

    into_fun = fn {:data, data}, {req, resp} ->
      resp =
        if resp.private[:stream_acc] == nil do
          ttfb = System.monotonic_time(:millisecond) - start_time
          initial_acc = %{content: "", usage: nil, first_chunk_time: ttfb}
          Req.Response.put_private(resp, :stream_acc, initial_acc)
        else
          resp
        end

      acc = resp.private.stream_acc

      case parse_gemini_sse(data) do
        {:chunks, chunks} ->
          {new_acc, openai_chunks} = process_gemini_chunks(acc, chunks)
          Enum.each(openai_chunks, &send_chunk.(&1))
          Process.put(:__google_stream_acc__, new_acc)
          {:cont, {req, Req.Response.put_private(resp, :stream_acc, new_acc)}}

        :done ->
          send_chunk.("data: [DONE]\n\n")
          {:halt, {req, resp}}

        :skip ->
          {:cont, {req, resp}}
      end
    end

    result =
      Req.post(url, headers: headers, json: body, receive_timeout: @timeout_ms, into: into_fun)

    Process.delete(:__google_stream_acc__)

    case result do
      {:ok, %Req.Response{status: 200} = resp} ->
        acc = resp.private[:stream_acc] || %{content: "", usage: nil, first_chunk_time: nil}

        upload_ms = calculate_upload_ms(start_time)

        timing_meta = %{
          payload_size_bytes: payload_size_bytes,
          upload_ms: upload_ms,
          provider_processing_ms: nil
        }

        {:ok, build_final_response(acc, timing_meta), %{headers: resp.headers}}

      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        reason = Adapter.categorize_error(status, body)

        {:error, reason,
         %{status: status, body: body, latency_ms: latency(start_time), headers: resp_headers}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout, %{latency_ms: latency(start_time)}}

      {:error, reason} ->
        {:error, :unknown, %{reason: reason, latency_ms: latency(start_time)}}
    end
  end

  def build_gemini_request(request) do
    messages = request["messages"] || []
    {system_instruction, contents} = extract_system_and_contents(messages)

    body = %{"contents" => contents}

    body =
      if system_instruction,
        do: Map.put(body, "systemInstruction", %{"parts" => [%{"text" => system_instruction}]}),
        else: body

    # Generation config
    gen_config = %{}

    gen_config =
      if request["temperature"],
        do: Map.put(gen_config, "temperature", request["temperature"]),
        else: gen_config

    gen_config =
      if request["top_p"], do: Map.put(gen_config, "topP", request["top_p"]), else: gen_config

    gen_config =
      if request["max_tokens"],
        do: Map.put(gen_config, "maxOutputTokens", request["max_tokens"]),
        else: gen_config

    gen_config =
      if request["stop"],
        do: Map.put(gen_config, "stopSequences", List.wrap(request["stop"])),
        else: gen_config

    if gen_config != %{}, do: Map.put(body, "generationConfig", gen_config), else: body
  end

  defp extract_system_and_contents(messages) do
    {system_msgs, other} = Enum.split_with(messages, &(&1["role"] == "system"))
    system = system_msgs |> Enum.map(& &1["content"]) |> Enum.join("\n\n")
    system = if system == "", do: nil, else: system

    contents =
      Enum.map(other, fn msg ->
        role = if msg["role"] == "assistant", do: "model", else: "user"
        %{"role" => role, "parts" => [%{"text" => msg["content"] || ""}]}
      end)

    {system, contents}
  end

  @doc false
  def convert_to_openai_format(gemini_response) do
    candidate = get_in(gemini_response, ["candidates", Access.at(0)]) || %{}
    content = get_in(candidate, ["content", "parts", Access.at(0), "text"]) || ""

    finish_reason =
      case candidate["finishReason"] do
        "STOP" -> "stop"
        "MAX_TOKENS" -> "length"
        "SAFETY" -> "content_filter"
        other -> other
      end

    usage =
      if gemini_response["usageMetadata"] do
        %{
          "prompt_tokens" => gemini_response["usageMetadata"]["promptTokenCount"],
          "completion_tokens" => gemini_response["usageMetadata"]["candidatesTokenCount"],
          "total_tokens" => gemini_response["usageMetadata"]["totalTokenCount"]
        }
      end

    response = %{
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => finish_reason
        }
      ]
    }

    if usage, do: Map.put(response, "usage", usage), else: response
  end

  defp parse_gemini_sse(data) do
    lines = data |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    chunks =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json ->
        case Jason.decode(json) do
          {:ok, parsed} -> parsed
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if chunks == [], do: :skip, else: {:chunks, chunks}
  end

  defp process_gemini_chunks(acc, chunks) do
    Enum.reduce(chunks, {acc, []}, fn chunk, {acc, openai_chunks} ->
      text =
        get_in(chunk, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) ||
          ""

      new_acc = %{acc | content: acc.content <> text}

      usage = chunk["usageMetadata"]

      new_acc =
        if usage,
          do: %{
            new_acc
            | usage: %{
                "prompt_tokens" => usage["promptTokenCount"],
                "completion_tokens" => usage["candidatesTokenCount"],
                "total_tokens" => usage["totalTokenCount"]
              }
          },
          else: new_acc

      if text != "" do
        openai_chunk =
          "data: #{Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => text}}]})}\n\n"

        {new_acc, openai_chunks ++ [openai_chunk]}
      else
        {new_acc, openai_chunks}
      end
    end)
  end

  defp build_final_response(acc, timing_meta) do
    meta = %{
      "ttfb_ms" => acc.first_chunk_time,
      "upload_ms" => timing_meta.upload_ms,
      "payload_size_bytes" => timing_meta.payload_size_bytes,
      "provider_processing_ms" => timing_meta.provider_processing_ms
    }

    response = %{
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => acc.content},
          "finish_reason" => "stop"
        }
      ],
      "_meta" => meta
    }

    if acc.usage, do: Map.put(response, "usage", acc.usage), else: response
  end

  defp latency(start_time), do: System.monotonic_time(:millisecond) - start_time

  defp calculate_upload_ms(start_time) do
    FinchTelemetry.get_upload_ms(start_time)
  end
end
