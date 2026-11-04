defmodule Mithril.ScheduledJobs.MessageDeliveryFallbackTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.ScheduledJobs.MessageDeliveryFallback

  setup do
    :ok = Sandbox.checkout(Repo)
    create_attempts_table!()
    :ok
  end

  test "due sms lookup accepts a datetime cutoff" do
    later = DateTime.utc_now() |> DateTime.add(3600, :second)

    Repo.query!(
      """
      INSERT INTO public.message_delivery_attempts
        (id, channel, status, fallback_after)
      VALUES ($1::uuid, 'sms', 'queued', $2::timestamptz)
      """,
      [Ecto.UUID.bingenerate(), later]
    )

    assert :ok = MessageDeliveryFallback.run()
  end

  defp create_attempts_table! do
    Repo.query!("DROP TABLE IF EXISTS public.message_delivery_attempts")

    Repo.query!("""
    CREATE TABLE public.message_delivery_attempts (
      id uuid PRIMARY KEY,
      user_id uuid,
      booking_id uuid,
      message_type text,
      template_key text,
      to_phone text,
      template_variables jsonb,
      channel text NOT NULL,
      status text NOT NULL,
      fallback_sent_at timestamptz,
      fallback_checked_at timestamptz,
      fallback_after timestamptz
    )
    """)
  end
end
