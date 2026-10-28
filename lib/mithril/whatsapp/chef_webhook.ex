defmodule Mithril.WhatsApp.ChefWebhook do
  @moduledoc """
  Signed Twilio inbound webhook for the dedicated chef WhatsApp bot.

  This bot is a separate sender from cleaner recruitment. Completed enquiries
  remain in public.whatsapp_chef_intakes pending a subsequent Direct placement
  integration. Never say an order was submitted to Direct until that
  integration succeeds.
  """

  alias Mithril.Repo
  alias Mithril.WhatsApp.ChefIntake
  alias Mithril.WhatsApp.TwilioSignature

  def configured? do
    present?(Application.get_env(:mithril, :twilio_auth_token)) and
      present?(Application.get_env(:mithril, :twilio_chef_webhook_url))
  end

  def handle(params, signature) when is_map(params) do
    cond do
      not configured?() ->
        {:error, :not_configured}

      not valid_signature?(params, signature) ->
        {:error, :unauthorized}

      not addressed_to_chef?(params) ->
        {:error, :invalid_request}

      true ->
        ingest(params)
    end
  end

  @doc "TwiML that sends cleaner-recruitment traffic to the chef WhatsApp line."
  def recruitment_redirect_twiml do
    twiml(recruitment_redirect_text())
  end

  def recruitment_redirect_text do
    case display_line(chef_from()) do
      nil ->
        "This WhatsApp line is for cleaner applications. Reply APPLY to start. Chef enquiries use a separate Instaclean WhatsApp bot."

      {display, link} ->
        "Chef enquiries have their own WhatsApp bot. Message #{display} or open #{link}."
    end
  end

  defp ingest(params) do
    from = Map.get(params, "From", "")
    sid = Map.get(params, "MessageSid", "")
    body = Map.get(params, "Body", "")

    if is_binary(from) and String.starts_with?(from, "whatsapp:+") and byte_size(from) <= 32 and
         is_binary(sid) and byte_size(sid) > 0 and byte_size(sid) <= 100 and is_binary(body) do
      transaction(from, sid, body)
    else
      {:error, :invalid_request}
    end
  end

  defp transaction(phone, sid, body) do
    Repo.transaction(fn ->
      case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", ["chef:" <> phone]) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      # Every webhook message is recorded atomically with the state transition.
      # A delayed Twilio retry cannot advance a later question.
      case Repo.query(
             """
             INSERT INTO public.whatsapp_chef_processed_messages (message_sid, phone, inserted_at)
             VALUES ($1, $2, now())
             ON CONFLICT (message_sid) DO NOTHING
             RETURNING message_sid
             """,
             [sid, phone]
           ) do
        {:ok, %{rows: []}} ->
          ""

        {:ok, %{rows: [[_]]}} ->
          process_message(phone, sid, String.upcase(String.trim(body)), body)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, answer} -> {:ok, twiml(answer)}
      {:error, _} -> {:error, :database}
    end
  end

  defp process_message(phone, sid, command, body) do
    row =
      case Repo.query(
             "SELECT step, status, answers FROM public.whatsapp_chef_intakes WHERE phone = $1",
             [phone]
           ) do
        {:ok, %{rows: [item]}} -> item
        {:ok, %{rows: []}} -> nil
        {:error, reason} -> Repo.rollback(reason)
      end

    cond do
      command == "EXIT" and match?([_, status, _] when status in ["in_progress", "confirm"], row) ->
        query_or_rollback(
          "UPDATE public.whatsapp_chef_intakes SET status = 'paused', last_message_sid = $2, updated_at = now() WHERE phone = $1",
          [phone, sid]
        )

        "Chef enquiry closed. Reply CHEF to begin again."

      command == "APPLY" ->
        cleaner_redirect_text()

      command == "CHEF" or row == nil or match?([_, "paused", _], row) ->
        {state, reply} = ChefIntake.start()
        store_state(phone, sid, state)
        reply

      true ->
        [step, status, answers] = row
        current = %{step: step, status: String.to_existing_atom(status), answers: answers}

        case ChefIntake.advance(current, body) do
          {state, reply, _completed_answers} ->
            # An immutable copy is saved before changing the active session.
            if status != "completed" do
              query_or_rollback(
                """
                INSERT INTO public.whatsapp_chef_completed_enquiries
                  (phone, answers, submitted_at, inserted_at, updated_at)
                VALUES ($1, $2::jsonb, now(), now(), now())
                """,
                [phone, Jason.encode!(state.answers)]
              )
            end

            store_state(phone, sid, state)
            reply <> "\nThank you. Our team will review your enquiry."

          {state, reply} ->
            store_state(phone, sid, state)
            reply
        end
    end
  end

  defp store_state(phone, sid, state) do
    query_or_rollback(
      """
      INSERT INTO public.whatsapp_chef_intakes
        (phone, step, status, answers, last_message_sid, submitted_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4::jsonb, $5,
        CASE WHEN $3 = 'completed' THEN now() ELSE NULL END, now(), now())
      ON CONFLICT (phone) DO UPDATE
        SET step = EXCLUDED.step, status = EXCLUDED.status,
            answers = EXCLUDED.answers, last_message_sid = EXCLUDED.last_message_sid,
            submitted_at = CASE WHEN EXCLUDED.status = 'completed' THEN now() ELSE NULL END,
            updated_at = now()
      """,
      [phone, state.step, Atom.to_string(state.status), Jason.encode!(state.answers), sid]
    )
  end

  defp query_or_rollback(sql, params) do
    case Repo.query(sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp valid_signature?(params, signature) do
    token = Application.get_env(:mithril, :twilio_auth_token)

    string_params =
      params
      |> Enum.filter(fn {_key, value} ->
        is_binary(value) or is_number(value) or is_boolean(value)
      end)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    Enum.any?(webhook_urls(), fn url ->
      TwilioSignature.valid?(string_params, signature, token, url)
    end)
  end

  defp webhook_urls do
    [
      Application.get_env(:mithril, :twilio_chef_webhook_url),
      Application.get_env(:mithril, :twilio_chef_webhook_url_alias)
    ]
    |> Enum.filter(&present?/1)
  end

  defp addressed_to_chef?(params) do
    case chef_from() do
      nil ->
        true

      expected ->
        canonical(Map.get(params, "To", "")) == canonical(expected)
    end
  end

  defp chef_from do
    case Application.get_env(:mithril, :twilio_chef_whatsapp_from) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp cleaner_redirect_text do
    case display_line(Application.get_env(:mithril, :twilio_whatsapp_from)) do
      nil ->
        "This WhatsApp line is for chef enquiries. To apply as a cleaner, visit tryinstaclean.com/join-as-cleaner."

      {display, link} ->
        "This WhatsApp line is for chef enquiries. To apply as a cleaner, message #{display} or open #{link}."
    end
  end

  defp display_line(value) when is_binary(value) do
    e164 =
      value
      |> String.trim()
      |> String.replace(~r/^whatsapp:/i, "")

    digits = String.replace(e164, ~r/\D/, "")

    if String.starts_with?(e164, "+") and byte_size(digits) >= 10 do
      {e164, "https://wa.me/#{digits}"}
    else
      nil
    end
  end

  defp display_line(_), do: nil

  defp canonical(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/^whatsapp:/i, "")
    |> String.replace(~r/\s+/, "")
  end

  defp canonical(_), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp twiml(""), do: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response></Response>"

  defp twiml(message) do
    escaped =
      message
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&apos;")

    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Message>#{escaped}</Message></Response>"
  end
end
