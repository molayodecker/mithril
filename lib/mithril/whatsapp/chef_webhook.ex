defmodule Mithril.WhatsApp.ChefWebhook do
  @moduledoc """
  Signed Twilio inbound webhook for the chef inquiry flow.

  Completed enquiries remain in public.whatsapp_chef_intakes pending a
  subsequent Direct placement integration. Never say an order was submitted
  to Direct until that integration succeeds.
  """

  alias Mithril.Repo
  alias Mithril.WhatsApp.ChefIntake
  alias Mithril.WhatsApp.TwilioSignature

  def handle(params, signature) when is_map(params) do
    token = Application.get_env(:mithril, :twilio_auth_token)
    url = Application.get_env(:mithril, :twilio_chef_webhook_url)
    valid_params =
      params
      |> Enum.filter(fn {_key, value} -> is_binary(value) end)
      |> Map.new()

    cond do
      not (is_binary(token) and byte_size(token) > 0 and is_binary(url) and byte_size(url) > 0) ->
        {:error, :not_configured}

      not TwilioSignature.valid?(valid_params, signature, token, url) ->
        {:error, :unauthorized}

      true ->
        from = Map.get(params, "From", "")
        sid = Map.get(params, "MessageSid", "")
        body = Map.get(params, "Body", "")

        if String.starts_with?(from, "whatsapp:+") and byte_size(from) <= 32 and
             is_binary(sid) and byte_size(sid) > 0 and byte_size(sid) <= 100 do
          transaction(from, sid, body)
        else
          {:error, :invalid_request}
        end
    end
  end

  @doc "Uses the recruitment endpoint's already-verified Twilio signature."
  def handle_verified(params) when is_map(params) do
    from = Map.get(params, "From", "")
    sid = Map.get(params, "MessageSid", "")
    body = Map.get(params, "Body", "")

    if is_binary(from) and String.starts_with?(from, "whatsapp:+") and
         byte_size(from) <= 32 and is_binary(sid) and
         byte_size(sid) > 0 and byte_size(sid) <= 100 and is_binary(body) do
      transaction(from, sid, body)
    else
      {:error, :invalid_request}
    end
  end

  @doc "Only unfinished chef conversations retain routing ownership."
  def active?(phone) when is_binary(phone) do
    case Repo.query(
      "SELECT 1 FROM public.whatsapp_chef_intakes WHERE phone = $1 AND status IN ('in_progress', 'confirm') LIMIT 1",
      [phone]
    ) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  defp transaction(phone, sid, body) do
    Repo.transaction(fn ->
      # An advisory transaction lock serializes replies from one sender.
      # Use the same transaction for the read and the write.
      case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", ["chef:" <> phone]) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      row =
        case Repo.query(
          "SELECT step, status, answers, last_message_sid FROM public.whatsapp_chef_intakes WHERE phone = $1",
          [phone]
        ) do
          {:ok, %{rows: [item]}} -> item
          {:ok, %{rows: []}} -> nil
          {:error, reason} -> Repo.rollback(reason)
        end

      if row != nil and Enum.at(row, 3) == sid do
        # Duplicate delivery: send no TwiML message.
        ""
      else
        {state, answer} =
          case row do
            nil ->
              ChefIntake.start()

            [step, status, answers, _] ->
              atom_status = String.to_existing_atom(status)
              current = %{step: step, status: atom_status, answers: answers}
              case ChefIntake.advance(current, body) do
                {next, text, _completed} ->
                  {next, text <> "\nThank you. Our team will review your enquiry."}

                {next, text} ->
                  {next, text}
              end
          end

        status = Atom.to_string(state.status)

        case Repo.query(
          """
          INSERT INTO public.whatsapp_chef_intakes
            (phone, step, status, answers, last_message_sid, submitted_at, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4::jsonb, $5,
            CASE WHEN $3 = 'completed' THEN now() ELSE NULL END, now(), now())
          ON CONFLICT (phone) DO UPDATE
            SET step = EXCLUDED.step, status = EXCLUDED.status,
                answers = EXCLUDED.answers, last_message_sid = EXCLUDED.last_message_sid,
                submitted_at = CASE WHEN EXCLUDED.status = 'completed'
                  THEN COALESCE(whatsapp_chef_intakes.submitted_at, now())
                  ELSE NULL END,
                updated_at = now()
          """,
          [phone, state.step, status, Jason.encode!(state.answers), sid]
        ) do
          {:ok, _} -> answer
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
    |> case do
      {:ok, answer} -> {:ok, twiml(answer)}
      {:error, _} -> {:error, :database}
    end
  end

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
