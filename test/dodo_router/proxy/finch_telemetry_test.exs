defmodule DodoRouter.Proxy.FinchTelemetryTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Proxy.FinchTelemetry

  describe "extract_provider_processing_ms/1" do
    test "extracts from list headers" do
      headers = [{"content-type", "application/json"}, {"openai-processing-ms", "42"}]
      assert FinchTelemetry.extract_provider_processing_ms(headers) == 42
    end

    test "extracts from map headers with list value" do
      headers = %{"openai-processing-ms" => ["42"]}
      assert FinchTelemetry.extract_provider_processing_ms(headers) == 42
    end

    test "extracts from map headers with string value" do
      headers = %{"openai-processing-ms" => "42"}
      assert FinchTelemetry.extract_provider_processing_ms(headers) == 42
    end

    test "returns nil when header not present in list" do
      headers = [{"content-type", "application/json"}]
      assert FinchTelemetry.extract_provider_processing_ms(headers) == nil
    end

    test "returns nil when header not present in map" do
      assert FinchTelemetry.extract_provider_processing_ms(%{}) == nil
    end

    test "returns nil for non-list/map input" do
      assert FinchTelemetry.extract_provider_processing_ms(nil) == nil
      assert FinchTelemetry.extract_provider_processing_ms("string") == nil
    end

    test "returns nil for unparseable value" do
      headers = [{"openai-processing-ms", "not-a-number"}]
      assert FinchTelemetry.extract_provider_processing_ms(headers) == nil
    end
  end

  describe "mark_request_start/0" do
    test "returns a monotonic time integer" do
      start_time = FinchTelemetry.mark_request_start()
      assert is_integer(start_time)
    end
  end

  describe "clear/0" do
    test "returns ok" do
      assert FinchTelemetry.clear() == :ok
    end
  end
end
