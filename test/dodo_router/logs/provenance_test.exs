defmodule DodoRouter.Logs.ProvenanceTest do
  use ExUnit.Case, async: true

  alias DodoRouter.Logs.Provenance

  defp sibling(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        final_provider: "test_provider",
        final_model: "model-one",
        inserted_at: ~U[2026-07-05 10:00:00.000000Z],
        response_body:
          Jason.encode!(%{
            "choices" => [
              %{"message" => %{"role" => "assistant", "content" => "Paris is the capital"}}
            ]
          })
      },
      attrs
    )
  end

  defp assistant(content, extra \\ %{}) do
    Map.merge(%{role: "assistant", content: content, tool_calls: nil}, extra)
  end

  test "attributes an assistant message whose content matches a sibling response" do
    s = sibling(%{})

    [_, annotated] =
      Provenance.annotate([%{role: "user", content: "q"}, assistant("Paris is the capital")], [s])

    assert annotated.producer == %{
             provider: "test_provider",
             model: "model-one",
             log_id: s.id
           }
  end

  test "matching ignores surrounding whitespace" do
    s = sibling(%{})

    [annotated] = Provenance.annotate([assistant("  Paris is the capital\n")], [s])
    assert annotated.producer.log_id == s.id
  end

  test "matches by tool-call id when content is empty" do
    s =
      sibling(%{
        response_body:
          Jason.encode!(%{
            "choices" => [
              %{
                "message" => %{
                  "role" => "assistant",
                  "content" => "",
                  "tool_calls" => [
                    %{"id" => "call_abc123", "type" => "function", "function" => %{}}
                  ]
                }
              }
            ]
          })
      })

    message =
      assistant("", %{tool_calls: [%{"id" => "call_abc123", "type" => "function"}]})

    [annotated] = Provenance.annotate([message], [s])
    assert annotated.producer.log_id == s.id
  end

  test "the earliest sibling wins for duplicate response content" do
    early = sibling(%{final_model: "early-model", inserted_at: ~U[2026-07-05 09:00:00.000000Z]})
    late = sibling(%{final_model: "late-model", inserted_at: ~U[2026-07-05 11:00:00.000000Z]})

    [annotated] = Provenance.annotate([assistant("Paris is the capital")], [late, early])
    assert annotated.producer.model == "early-model"
  end

  test "unmatched assistant messages get no producer" do
    [annotated] = Provenance.annotate([assistant("something the client edited")], [sibling(%{})])
    refute Map.has_key?(annotated, :producer)
  end

  test "non-assistant messages are untouched" do
    user_msg = %{role: "user", content: "Paris is the capital"}

    [annotated] = Provenance.annotate([user_msg], [sibling(%{})])
    assert annotated == user_msg
  end
end
