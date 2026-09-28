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
      complete: Application.get_env(:mithril, :openai_complete),
      candidates: Application.get_env(:mithril, :ai_match_candidate_loader)
    }

    Application.put_env(:mithril, :ai_match_candidate_loader, fn _body, requested ->
      {:ok, requested}
    end)

    on_exit(fn ->
      restore(:ai_match_settings, previous.settings)
      restore(:openai_api_key, previous.key)
      restore(:openai_complete, previous.complete)
      restore(:ai_match_candidate_loader, previous.candidates)
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

  test "rejects AI rankings that contain unknown cleaner ids" do
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
    assert body.source == "fallback"
    assert body.reason == "ai_insufficient_rows"
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

  test "invalid booking draft fails closed instead of returning client candidates" do
    Application.put_env(:mithril, :ai_match_candidate_loader, fn _body, _requested ->
      flunk("candidate loader should not run for an invalid draft")
    end)

    assert {:ok, body} =
             RankCleanersWithAi.call(nil, %{
               "cleaners" => @cleaners,
               "bookingDraft" => %{
                 "bookingDate" => "not-a-date",
                 "slotTime24h" => "10:00",
                 "latitude" => 5.6,
                 "longitude" => -0.2,
                 "serviceId" => 1,
                 "durationHours" => 2
               }
             })

    assert body.source == "fallback"
    assert body.reason == "invalid_booking_date"
    assert body.cleaners == []
  end

  test "candidate lookup failure fails closed instead of returning client candidates" do
    Application.put_env(:mithril, :ai_match_candidate_loader, fn _body, _requested ->
      {:fallback, "candidate_lookup_failed"}
    end)

    assert {:ok, body} = RankCleanersWithAi.call(nil, %{"cleaners" => @cleaners})
    assert body.source == "fallback"
    assert body.reason == "candidate_lookup_failed"
    assert body.cleaners == []
  end

  test "post-loader fallback ranks only authoritative candidates" do
    enable_settings()
    Application.delete_env(:mithril, :openai_api_key)

    Application.put_env(:mithril, :ai_match_candidate_loader, fn _body, _requested ->
      {:ok,
       [
         %{
           id: "server-only",
           name: "Server candidate",
           company_name: nil,
           bio: nil,
           rating: 5,
           distance: 1,
           hourly_rate: 50,
           match_score: 99,
           years_experience: 4,
           jobs_completed: 20,
           completed_jobs: 20
         }
       ]}
    end)

    assert {:ok, body} = RankCleanersWithAi.call(nil, %{"cleaners" => @cleaners})
    assert body.reason == "missing_openai_key"
    assert Enum.map(body.cleaners, & &1.cleaner_id) == ["server-only"]
  end

  test "integer service ids are accepted in booking drafts" do
    enable_settings()
    Application.put_env(:mithril, :openai_api_key, "sk-test")

    Application.put_env(:mithril, :ai_match_candidate_loader, fn body, requested ->
      assert get_in(body, ["bookingDraft", "serviceId"]) == 1
      {:ok, requested}
    end)

    Application.put_env(:mithril, :openai_complete, fn _params ->
      {:ok,
       [
         %{cleaner_id: "b", score: 90, reason: "r"},
         %{cleaner_id: "c", score: 80, reason: "r"},
         %{cleaner_id: "a", score: 70, reason: "r"}
       ]}
    end)

    date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    assert {:ok, %{source: "ai"}} =
             RankCleanersWithAi.call(nil, %{
               "cleaners" => @cleaners,
               "bookingDraft" => %{
                 "bookingDate" => date,
                 "slotTime24h" => "10:00",
                 "latitude" => 5.6,
                 "longitude" => -0.2,
                 "serviceId" => 1,
                 "durationHours" => 2
               }
             })
  end

  test "deterministic fallback preserves authoritative availability order without faking distance" do
    enable_settings()
    Application.delete_env(:mithril, :openai_api_key)

    Application.put_env(:mithril, :ai_match_candidate_loader, fn _body, _requested ->
      {:ok,
       [
         %{
           id: "first",
           name: "First",
           company_name: nil,
           bio: nil,
           rating: 4.5,
           distance: nil,
           availability_rank: 1,
           hourly_rate: 60,
           match_score: nil,
           years_experience: nil,
           jobs_completed: 10,
           completed_jobs: 10
         },
         %{
           id: "second",
           name: "Second",
           company_name: nil,
           bio: nil,
           rating: 4.9,
           distance: nil,
           availability_rank: 2,
           hourly_rate: 70,
           match_score: nil,
           years_experience: nil,
           jobs_completed: 20,
           completed_jobs: 20
         }
       ]}
    end)

    assert {:ok, body} = RankCleanersWithAi.call(nil, %{"cleaners" => @cleaners})
    assert body.reason == "missing_openai_key"
    assert Enum.map(body.cleaners, & &1.cleaner_id) == ["first", "second"]
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
