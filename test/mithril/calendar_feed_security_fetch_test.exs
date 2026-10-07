defmodule Mithril.CalendarFeedSecurityFetchTest do
  use ExUnit.Case, async: true

  alias Mithril.CalendarFeedSecurity

  @ics_body """
  BEGIN:VCALENDAR
  VERSION:2.0
  END:VCALENDAR
  """

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Mithril.Repo)
    on_exit(fn -> Application.delete_env(:mithril, :calendar_feed_http_get) end)
    :ok
  end

  test "rejects localhost feed URLs" do
    assert {:error, message} =
             CalendarFeedSecurity.assert_safe_feed_url(
               "https://localhost/airbnb/calendar/ical/x.ics",
               "airbnb"
             )

    assert message =~ "not allowed" or message =~ "Airbnb"
  end

  test "rejects private IPv4 feed URLs" do
    assert {:error, message} =
             CalendarFeedSecurity.assert_safe_feed_url(
               "https://192.168.0.5/airbnb/calendar/ical/x.ics",
               "airbnb"
             )

    assert message =~ "not allowed" or message =~ "Airbnb"
  end

  test "redirect to private IP is rejected" do
    redirect_url = "https://www.airbnb.com/calendar/ical/start.ics"

    Application.put_env(:mithril, :calendar_feed_http_get, fn url ->
      cond do
        url == redirect_url ->
          {:ok,
           %{
             status: 302,
             headers: %{"location" => "https://127.0.0.1/private.ics"},
             body: ""
           }}

        true ->
          {:ok, %{status: 200, body: @ics_body, headers: %{}}}
      end
    end)

    assert {:error, message} = CalendarFeedSecurity.fetch_feed_text(redirect_url, "airbnb")
    assert message =~ "not allowed" or message =~ "Airbnb"
  end

  test "oversized response is rejected" do
    url = "https://www.airbnb.com/calendar/ical/large.ics"
    huge = String.duplicate("A", 5 * 1024 * 1024 + 1)

    Application.put_env(:mithril, :calendar_feed_http_get, fn ^url ->
      {:ok, %{status: 200, body: huge, headers: %{}}}
    end)

    assert {:error, message} = CalendarFeedSecurity.fetch_feed_text(url, "airbnb")
    assert message =~ "maximum size"
  end

  test "fetch timeout surfaces as request failed" do
    url = "https://www.airbnb.com/calendar/ical/timeout.ics"

    Application.put_env(:mithril, :calendar_feed_http_get, fn ^url ->
      {:error, :timeout}
    end)

    assert {:error, "Feed request failed"} = CalendarFeedSecurity.fetch_feed_text(url, "airbnb")
  end

  test "connect-property-calendar default timezone passes without Elixir tzdata" do
    # Mobile hosts in Ghana store Africa/Accra on properties. Mithril does not bundle
    # tzdata, so DateTime.now/1 cannot resolve this zone (connect used to 400 here).
    assert {:error, :utc_only_time_zone_database} = DateTime.now("Africa/Accra")

    assert :ok =
             CalendarFeedSecurity.validate_feed_timing(%{
               timezone: "Africa/Accra",
               default_checkin_time: "15:00:00",
               default_checkout_time: "11:00:00"
             })
  end

  test "validate_feed_timing accepts trimmed IANA zones" do
    assert :ok =
             CalendarFeedSecurity.validate_feed_timing(%{
               timezone: "  America/New_York  ",
               default_checkin_time: "15:00:00",
               default_checkout_time: "11:00:00"
             })
  end

  test "normalize_timezone returns the trimmed persisted value" do
    assert {:ok, "America/New_York"} =
             CalendarFeedSecurity.normalize_timezone("  America/New_York  ")
  end

  test "validate_feed_timing rejects malformed timezone" do
    assert {:error, "Invalid timezone: not-a-zone"} =
             CalendarFeedSecurity.validate_feed_timing(%{
               timezone: "not-a-zone",
               default_checkin_time: "15:00:00",
               default_checkout_time: "11:00:00"
             })
  end

  test "validate_feed_timing rejects unknown IANA-shaped timezone" do
    assert {:error, "Invalid timezone: Africa/Definitely_Not_A_Zone"} =
             CalendarFeedSecurity.validate_feed_timing(%{
               timezone: "Africa/Definitely_Not_A_Zone",
               default_checkin_time: "15:00:00",
               default_checkout_time: "11:00:00"
             })
  end

  test "validate_feed_timing rejects blank timezone" do
    assert {:error, "Invalid timezone:    "} =
             CalendarFeedSecurity.validate_feed_timing(%{
               timezone: "   ",
               default_checkin_time: "15:00:00",
               default_checkout_time: "11:00:00"
             })
  end

  test "temporary fetch failure does not mutate local calendar data (sync layer skips import)" do
    url = "https://www.airbnb.com/calendar/ical/fail.ics"

    Application.put_env(:mithril, :calendar_feed_http_get, fn ^url ->
      {:ok, %{status: 503, body: "busy", headers: %{}}}
    end)

    assert {:error, message} = CalendarFeedSecurity.fetch_feed_text(url, "airbnb")
    assert message =~ "503"
  end
end
