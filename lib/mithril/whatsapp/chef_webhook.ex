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

  @doc "Checks chef ownership and propagates database failures."
  def active?(phone) when is_binary(phone) do
    case Repo.query(
           "SELECT status FROM public.whatsapp_chef_intakes WHERE phone = $1",
           [phone]
         ) do
      {:ok, %{rows: [[status]]}} -> {:ok, status in ["in_progress", "confirm"]}
      {:ok, %{rows: []}} -> {:ok, false}
      {:error, _} -> {:error, :database}
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

        "Chef enquiry closed. You can now reply APPLY to start a cleaner application, or CHEF to begin again."

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
