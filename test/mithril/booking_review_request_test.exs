defmodule Mithril.BookingReviewRequestTest do
  use ExUnit.Case, async: true

  alias Mithril.BookingReviewRequest

  test "due respects delay hours" do
    completed = ~U[2099-01-01 10:00:00Z]
    now_ms = DateTime.to_unix(~U[2099-01-01 11:30:00Z], :millisecond)
    refute BookingReviewRequest.due?(completed, now_ms, 2.0)
    assert BookingReviewRequest.due?(completed, now_ms, 1.0)
  end

  test "buildReviewRequestUrl uses token path" do
    url = BookingReviewRequest.build_url("https://tryinstaclean.com", "abc-123")
    assert url == "https://tryinstaclean.com/review/abc-123"
  end
end
