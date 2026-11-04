defmodule Mithril.WhatsApp.UnreachableTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.Repo
  alias Mithril.WhatsApp.Recruitment.Outbound
  alias Mithril.WhatsApp.Unreachable

  setup do
    :ok = Sandbox.checkout(Repo)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.whatsapp_unreachable_numbers (
      phone_e164 text PRIMARY KEY,
      twilio_code integer NOT NULL CHECK (twilio_code IN (63003, 63024)),
      first_seen_at timestamptz NOT NULL DEFAULT now(),
      last_seen_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    :ok
  end

  test "a 63024 rejection is saved and later WhatsApp sends stop" do
    assert :recorded = Unreachable.remember("whatsapp:+233555000111", %{"code" => 63024})
    assert Unreachable.unreachable?("+233555000111")

    previous = Application.get_env(:mithril, :twilio_http)
    Application.put_env(:mithril, :twilio_http, fn _ -> flunk("twilio should not be called") end)

    on_exit(fn ->
      if previous do
        Application.put_env(:mithril, :twilio_http, previous)
      else
        Application.delete_env(:mithril, :twilio_http)
      end
    end)

    assert {:error, :not_on_whatsapp} =
             Outbound.send_content("whatsapp:+233555000111", "whatsapp:+233500000000", "HX1", %{})

    assert {:error, :not_on_whatsapp} =
             Outbound.send_plain_text("whatsapp:+233555000111", "whatsapp:+233500000000", "Hello")
  end

  test "other provider errors are not stored" do
    assert :ignored = Unreachable.remember("+233555000222", %{"code" => 21610})
    refute Unreachable.unreachable?("+233555000222")
  end
end
