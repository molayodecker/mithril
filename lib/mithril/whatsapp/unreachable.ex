defmodule Mithril.WhatsApp.Unreachable do
  @moduledoc false

  require Logger

  alias Mithril.Auth.Phone
  alias Mithril.Repo

  @codes [63003, 63024]
  @code_strings ["63003", "63024"]

  def unreachable?(phone) when is_binary(phone) do
    case Repo.query(
           "SELECT 1 FROM public.whatsapp_unreachable_numbers WHERE phone_e164 = $1",
           [phone]
         ) do
      {:ok, %{num_rows: count}} when count > 0 -> true
      {:ok, _} -> false
      {:error, error} ->
        Logger.warning("whatsapp unreachable lookup failed: #{Exception.message(error)}")
        false
    end
  end

  def unreachable?(_), do: false

  @doc """
  Stores a Twilio 63003 or 63024 rejection for `address`.

  Returns `:recorded` when the body is one of those codes, even if the insert
  fails, so the current send still tells the caller the number is not on WhatsApp.
  """
  def remember(address, body) do
    case {code(body), phone(address)} do
      {twilio_code, {:ok, phone}} when is_integer(twilio_code) ->
        _ = record(phone, twilio_code)
        :recorded

      _ ->
        :ignored
    end
  end

  def phone(value) when is_binary(value) do
    value
    |> String.replace(~r/^whatsapp:/i, "")
    |> Phone.normalize()
  end

  def phone(_), do: :error

  defp record(phone, twilio_code) do
    case Repo.query(
           """
           INSERT INTO public.whatsapp_unreachable_numbers (phone_e164, twilio_code)
           VALUES ($1, $2)
           ON CONFLICT (phone_e164) DO UPDATE
           SET twilio_code = EXCLUDED.twilio_code,
               last_seen_at = now()
           """,
           [phone, twilio_code]
         ) do
      {:ok, _} -> :ok
      {:error, error} ->
        Logger.warning("whatsapp unreachable record failed: #{Exception.message(error)}")
        :error
    end
  end

  defp code(%{"code" => twilio_code}) when twilio_code in @codes, do: twilio_code

  defp code(%{"code" => twilio_code}) when twilio_code in @code_strings,
    do: String.to_integer(twilio_code)

  defp code(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> code(decoded)
      _ -> nil
    end
  end

  defp code(_), do: nil
end
