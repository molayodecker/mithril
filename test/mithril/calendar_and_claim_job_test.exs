defmodule Mithril.CalendarFeedSecurityTest do
  use ExUnit.Case, async: true

  alias Mithril.CalendarFeedSecurity

  test "accepts a valid Airbnb https ics URL" do
    assert :ok =
             CalendarFeedSecurity.assert_safe_feed_url(
               "https://www.airbnb.com/calendar/ical/abc.ics",
               "airbnb"
             )
  end

  test "rejects non-https feed URLs" do
    assert {:error, message} =
             CalendarFeedSecurity.assert_safe_feed_url(
               "http://www.airbnb.com/calendar/ical/abc.ics",
               "airbnb"
             )

    assert message =~ "HTTPS"
  end

  test "rejects unsupported providers" do
    assert {:error, message} = CalendarFeedSecurity.parse_provider("vrbo")
    assert message =~ "Unsupported"
  end
end

defmodule Mithril.MobileFunctions.ClaimJobTest do
  use ExUnit.Case, async: true

  alias Mithril.MobileFunctions.ClaimJob

  test "requires job_id" do
    user_id = Ecto.UUID.generate()

    assert {:error, {:status, 400, %{success: false, error: "Missing job_id"}}} =
             ClaimJob.call(user_id, %{})
  end

  test "rejects claiming a job without an offer" do
    user_id = Ecto.UUID.generate()
    job_id = Ecto.UUID.generate()

    assert {:error, {:status, 403, %{success: false, error: "Forbidden"}}} =
             ClaimJob.call(user_id, %{"job_id" => job_id})
  end
end
