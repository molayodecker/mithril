defmodule Mithril.MobileFunctions.RankCleanersWithAiTest do
  use ExUnit.Case, async: false

  alias Mithril.MobileFunctions.RankCleanersWithAi

  @cleaners [
    %{"id" => "a", "match_score" => 1, "distance" => 4},
    %{"id" => "b", "match_score" => 3, "distance" => 8},
    %{"id" => "c", "match_score" => 2, "distance" => 1}
  ]

  setup do
    previous = %{
      settings: Application.get_env(:mithril, :ai_match_settings),
      key: Application.get_env(:mithril, :openai_api_key),
      complete: Application.get_env(:mithril, :openai_complete)
    }

    on_exit(fn ->
      restore(:ai_match_settings, previous.settings)
      restore(:openai_api_key, previous.key)
      restore(:openai_complete, previous.complete)
    end)

    :ok
  end

  test "returns deterministic fallback ranking when AI is disabled" do
    assert {:ok, body} = RankCleanersWithAi.call(nil, %{"cleaners" => @cleaners})
    assert body.source == "fallback"
    assert body.reason == "disabled"
    assert hd(body.cleaners).cleaner_id == "b"
  end

  test "rejects a non-list cleaners payload" do
    assert {:error, {:status, 400, %{error: "Invalid cleaners payload"}}} =
             RankCleanersWithAi.call(nil, %{"cleaners" => "nope"})
  end

  test "returns empty fallback for no cleaners" do
    assert {:ok, %{cleaners: [], source: "fallback"}} =
             RankCleanersWithAi.call(nil, %{"cleaners" => []})
  end

  test "falls back when the OpenAI key is missing" do
    enable_settings()
    Application.delete_env(:mithril, :openai_api_key)

    assert {:ok, body} = RankCleanersWithAi.call(nil, %{"cleaners" => @cleaners})
    assert body.source == "fallback"
    assert body.reason == "missing_openai_key"
  end

  test "uses injected OpenAI ranking and drops unknown cleaner ids" do
    enable_settings()
    Application.put_env(:mithril, :openai_api_key, "sk-test")

    Application.put_env(:mithril, :openai_complete, fn params ->
      assert params.model == "gpt-4o-mini"
      assert Enum.map(params.cleaners, & &1.id) == ["a", "b", "c"]

      {:ok,
       [
         %{cleaner_id: "c", score: 99, reason: "Closest"},
         %{cleaner_id: "injected", score: 100, reason: "ignored"},
         %{cleaner_id: "b", score: 80, reason: "High score"},
         %{cleaner_id: "a", score: 10, reason: "Far"}
       ]}
    end)

    assert {:ok, body} = RankCleanersWithAi.call("user-1", %{"cleaners" => @cleaners})
    assert body.source == "ai"
    assert body.model == "gpt-4o-mini"
    assert Enum.map(body.cleaners, & &1.cleaner_id) == ["c", "b", "a"]
  end

  test "falls back when AI returns too few valid rows" do
    enable_settings()
    Application.put_env(:mithril, :openai_api_key, "sk-test")

    Application.put_env(:mithril, :openai_complete, fn _params ->
      {:ok, [%{cleaner_id: "b", score: 90, reason: "only one"}]}
    end)

    assert {:ok, body} = RankCleanersWithAi.call(nil, %{"cleaners" => @cleaners})
    assert body.source == "fallback"
    assert body.reason == "ai_insufficient_rows"
  end

  test "falls back when OpenAI fails" do
    enable_settings()
    Application.put_env(:mithril, :openai_api_key, "sk-test")
    Application.put_env(:mithril, :openai_complete, fn _params -> {:error, "openai_failed"} end)

    assert {:ok, body} = RankCleanersWithAi.call(nil, %{"cleaners" => @cleaners})
    assert body.source == "fallback"
    assert body.reason == "openai_failed"
  end

  test "rate limits per user without calling OpenAI" do
    enable_settings()
    Application.put_env(:mithril, :openai_api_key, "sk-test")
    user_id = "ai-rank-rate-limit-#{System.unique_integer([:positive])}"
    calls = :atomics.new(1, [])

    Application.put_env(:mithril, :openai_complete, fn _params ->
      :atomics.add(calls, 1, 1)

      {:ok,
       [
         %{cleaner_id: "b", score: 90, reason: "r"},
         %{cleaner_id: "c", score: 80, reason: "r"},
         %{cleaner_id: "a", score: 70, reason: "r"}
       ]}
    end)

    for _ <- 1..30 do
      assert {:ok, %{source: "ai"}} = RankCleanersWithAi.call(user_id, %{"cleaners" => @cleaners})
    end

    assert {:ok, body} = RankCleanersWithAi.call(user_id, %{"cleaners" => @cleaners})
    assert body.source == "fallback"
    assert body.reason == "rate_limited"
    assert :atomics.get(calls, 1) == 30
  end

  defp enable_settings do
    Application.put_env(:mithril, :ai_match_settings, %{
      "enabled" => true,
      "model" => "gpt-4o-mini",
      "fallback_model" => "gpt-4o-mini",
      "allowed_models" => ["gpt-4o-mini", "gpt-4o"],
      "temperature" => 0.2,
      "max_tokens" => 2000,
      "response_format" => "json_object"
    })
  end

  defp restore(key, nil), do: Application.delete_env(:mithril, key)
  defp restore(key, value), do: Application.put_env(:mithril, key, value)
end
