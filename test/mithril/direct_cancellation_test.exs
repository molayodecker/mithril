defmodule Mithril.DirectCancellationTest do
  use ExUnit.Case, async: true

  alias Mithril.DirectCancellation

  @now ~U[2026-09-11 12:00:00Z]

  test "paid bookings 24 hours or more away get a full refund" do
    policy =
      DirectCancellation.evaluate(
        %{
          status: "scheduled",
          payment_status: "paid",
          scheduled_date: ~D[2026-09-14],
          scheduled_at: ~U[2026-09-14 10:00:00Z],
          local_today: ~D[2026-09-11],
          amount_minor: 19_350
        },
        @now
      )

    assert policy.can_cancel
    assert policy.tier == "full_refund"
    assert policy.refund_percent == 100
    assert policy.refund_amount_minor == 19_350
    assert policy.success_message =~ "full refund of ₵193.50"
  end

  test "paid bookings inside 24 hours get a 50% refund" do
    policy =
      DirectCancellation.evaluate(
        %{
          status: "confirmed",
          payment_status: "paid",
          scheduled_date: ~D[2026-09-12],
          scheduled_at: ~U[2026-09-12 08:00:00Z],
          local_today: ~D[2026-09-11],
          amount_minor: 20_000
        },
        @now
      )

    assert policy.tier == "partial_refund"
    assert policy.refund_percent == 50
    assert policy.refund_amount_minor == 10_000
    assert policy.success_message =~ "50% refund"
  end

  test "same-day paid bookings are cancellable with no refund" do
    policy =
      DirectCancellation.evaluate(
        %{
          status: "pending",
          payment_status: "paid",
          scheduled_date: ~D[2026-09-11],
          scheduled_at: ~U[2026-09-11 18:00:00Z],
          local_today: ~D[2026-09-11],
          amount_minor: 19_350
        },
        @now
      )

    assert policy.can_cancel
    assert policy.tier == "no_refund"
    assert policy.refund_percent == 0
    assert policy.refund_amount_minor == 0
    assert policy.success_message =~ "No refund applies"
  end

  test "unpaid bookings cancel without a Paystack refund" do
    policy =
      DirectCancellation.evaluate(
        %{
          status: "scheduled",
          payment_status: "pending",
          scheduled_date: ~D[2026-09-14],
          scheduled_at: ~U[2026-09-14 10:00:00Z],
          local_today: ~D[2026-09-11],
          amount_minor: 19_350
        },
        @now
      )

    assert policy.can_cancel
    assert policy.tier == "full_refund"
    assert policy.refund_percent == 0
    assert policy.refund_amount_minor == 0
    assert policy.success_message == "Your booking has been cancelled."
  end

  test "in-progress visits cannot be cancelled" do
    policy =
      DirectCancellation.evaluate(
        %{
          status: "in_progress",
          payment_status: "paid",
          scheduled_date: ~D[2026-09-11],
          scheduled_at: ~U[2026-09-11 10:00:00Z],
          local_today: ~D[2026-09-11],
          amount_minor: 19_350
        },
        @now
      )

    refute policy.can_cancel
    assert policy.error_message =~ "on the way or the visit is in progress"
  end

  test "completed bookings cannot be cancelled" do
    policy =
      DirectCancellation.evaluate(%{
        status: "completed",
        payment_status: "paid",
        amount_minor: 19_350
      })

    refute policy.can_cancel
    assert policy.error_message == "Completed bookings cannot be cancelled."
  end
end
