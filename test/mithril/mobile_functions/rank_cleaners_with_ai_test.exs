defmodule Mithril.MobileFunctions.RankCleanersWithAiTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.MobileFunctions.RankCleanersWithAi
  alias Mithril.Repo
  alias Mithril.Transport.Ranking

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

  test "passes an HH:MM slot to nearby cleaner lookup as a time struct" do
    install_nearby_time_probe!()
    Application.delete_env(:mithril, :ai_match_candidate_loader)

    cleaner_id = Ecto.UUID.generate()
    date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    assert {:ok, body} =
             RankCleanersWithAi.call(nil, %{
               "cleaners" => [%{"id" => cleaner_id, "match_score" => 1, "distance" => 1}],
               "bookingDraft" => %{
                 "bookingDate" => date,
                 "slotTime24h" => "06:00",
                 "latitude" => 5.6,
                 "longitude" => -0.2,
                 "serviceId" => 1,
                 "durationHours" => 2
               }
             })

    refute body.reason in [
             "candidate_lookup_failed",
             "missing_service",
             "invalid_booking_time",
             "invalid_candidate_ids"
           ]

    assert_recorded_slot!(~T[06:00:00])
  end

  test "destination ranking passes an HH:MM slot as a time struct" do
    install_nearby_time_probe!()
    date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    assert {:ok, body} =
             Ranking.for_destination(Ecto.UUID.generate(), %{
               "lat" => 5.65,
               "lng" => -0.18,
               "scheduled_date" => date,
               "start_time" => "06:00",
               "duration_hours" => 2
             })

    assert body.provider == "locationiq"

    assert_recorded_slot!(~T[06:00:00])
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

  defp assert_recorded_slot!(expected) do
    assert [[recorded]] = Repo.query!("SELECT start_time FROM public.test_nearby_slot_calls").rows
    assert Time.compare(recorded, expected) == :eq
  end

  defp install_nearby_time_probe! do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to install nearby cleaner fixtures outside mithril_test, got #{inspect(database)}"
    end

    Repo.query!("DROP TABLE IF EXISTS public.service_types CASCADE")

    Repo.query!("""
    CREATE TABLE public.service_types (
      id integer PRIMARY KEY,
      specialty_slug text NOT NULL,
      active boolean NOT NULL DEFAULT true
    )
    """)

    Repo.query!(
      "INSERT INTO public.service_types (id, specialty_slug, active) VALUES (1, 'regular_cleaning', true)"
    )

    Repo.query!("DROP TABLE IF EXISTS public.test_nearby_slot_calls")

    Repo.query!("""
    CREATE TABLE public.test_nearby_slot_calls (
      start_time time NOT NULL
    )
    """)

    Repo.query!("""
    DROP FUNCTION IF EXISTS public.get_nearby_available_cleaners(
      double precision, double precision, integer, date, time, integer
    )
    """)

    Repo.query!("""
    CREATE FUNCTION public.get_nearby_available_cleaners(
      double precision, double precision, integer, date, time, integer
    ) RETURNS TABLE(id uuid)
    LANGUAGE plpgsql
    AS $$
    BEGIN
      INSERT INTO public.test_nearby_slot_calls(start_time) VALUES ($5);
      RETURN;
    END;
    $$
    """)
  end

  test "nearby cleaner duration is an integer Postgrex can encode" do
    assert RankCleanersWithAi.duration_query_param(3.4899999999999998) == 3
    assert RankCleanersWithAi.duration_query_param("3.5") == 3
    assert RankCleanersWithAi.duration_query_param(2) == 2
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
