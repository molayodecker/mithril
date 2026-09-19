defmodule Mithril.DirectAdminWhatsApp do
  @moduledoc "Staff WhatsApp inbox: threads, messages, and outbound session sends."

  require Logger

  alias Mithril.Auth
  alias Mithril.Auth.Phone
  alias Mithril.Auth.SMS
  alias Mithril.Repo
  alias Mithril.WhatsApp.Recruitment.Outbound

  def list_threads(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid) do
      case Repo.query("""
           SELECT jsonb_build_object(
             'phoneE164', t.phone_e164,
             'lastAt', t.created_at,
             'preview', left(t.body, 120),
             'userId', t.user_id,
             'displayLabel', COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               t.phone_e164
             )
           )
           FROM (
             SELECT DISTINCT ON (phone_e164)
               phone_e164, created_at, body, user_id
             FROM public.whatsapp_inbox_messages
             ORDER BY phone_e164, created_at DESC
           ) t
           LEFT JOIN public.profiles p ON p.id = t.user_id
           ORDER BY t.created_at DESC
           LIMIT 200
           """) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_messages(user_id, phone) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, e164} <- normalize_phone(phone) do
      case Repo.query(
             """
             SELECT jsonb_build_object(
               'id', m.id,
               'direction', m.direction,
               'phoneE164', m.phone_e164,
               'body', m.body,
               'createdAt', m.created_at,
               'userId', m.user_id,
               'sentByUserId', m.sent_by_user_id,
               'businessPhoneE164', m.business_phone_e164
             )
             FROM public.whatsapp_inbox_messages m
             WHERE m.phone_e164 = $1
             ORDER BY m.created_at ASC
             LIMIT 500
             """,
             [e164]
           ) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_message(user_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, e164} <- normalize_phone(params["phoneE164"] || params[:phoneE164]),
         {:ok, body} <- required_body(params["body"] || params[:body]),
         {:ok, from} <-
           admin_from(
             params["businessPhoneE164"] || params[:businessPhoneE164] || last_business(e164)
           ),
         :ok <- deliver_whatsapp(e164, from, body),
         {:ok, thread_user} <- resolve_user_id(e164) do
      insert_outbound(e164, body, thread_user, admin_uid, from)
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_sms(user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, e164} <- normalize_phone(params["phoneE164"] || params[:phoneE164]),
         {:ok, body} <- required_body(params["body"] || params[:body]) do
      case SMS.send_message(e164, body) do
        :ok -> {:ok, %{"ok" => true}}
        {:error, :sms_not_configured} -> {:error, :sms_not_configured}
        {:error, _} -> {:error, :sms_delivery_failed}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_whatsapp(e164, from, body) do
    to = whatsapp_address(e164)
    from_addr = whatsapp_address(from)

    case Outbound.send_plain_text(to, from_addr, body) do
      :ok -> :ok
      {:error, :twilio_not_configured} -> {:error, :twilio_not_configured}
      {:error, _} -> {:error, :sms_delivery_failed}
    end
  end

  defp insert_outbound(e164, body, thread_user, admin_uid, from) do
    case Repo.query(
           """
           INSERT INTO public.whatsapp_inbox_messages (
             direction, phone_e164, body, user_id, sent_by_user_id, business_phone_e164
           ) VALUES ('outbound', $1, $2, $3, $4, $5)
           RETURNING id
           """,
           [e164, body, thread_user, admin_uid, digits_only(from)]
         ) do
      {:ok, _} -> {:ok, %{"ok" => true}}
      {:error, error} -> database_error(error)
    end
  end

  defp last_business(e164) do
    case Repo.query(
           """
           SELECT business_phone_e164
           FROM public.whatsapp_inbox_messages
           WHERE phone_e164 = $1 AND business_phone_e164 IS NOT NULL
           ORDER BY created_at DESC
           LIMIT 1
           """,
           [e164]
         ) do
      {:ok, %{rows: [[phone]]}} when is_binary(phone) -> phone
      _ -> Application.get_env(:mithril, :twilio_whatsapp_admin_from)
    end
  end

  defp admin_from(nil), do: admin_from(Application.get_env(:mithril, :twilio_whatsapp_admin_from))
  defp admin_from(""), do: admin_from(nil)

  defp admin_from(value) when is_binary(value) do
    case normalize_phone(value) do
      {:ok, e164} -> {:ok, e164}
      _ -> {:error, :twilio_not_configured}
    end
  end

  defp admin_from(_), do: {:error, :twilio_not_configured}

  defp resolve_user_id(e164) do
    variants = phone_variants(e164)

    case Repo.query(
           """
           SELECT id FROM public.users
           WHERE phone = ANY($1::text[])
           LIMIT 1
           """,
           [variants]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, error} -> database_error(error)
    end
  end

  defp phone_variants(e164) do
    digits = String.replace(e164, ~r/\D/, "")

    local =
      if String.starts_with?(digits, "233"), do: "0" <> String.slice(digits, 3..-1//1), else: nil

    [e164, "+" <> digits, digits, local] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp required_body(value) when is_binary(value) do
    body = String.trim(value)

    cond do
      body == "" -> {:error, :invalid_request}
      String.length(body) > 2000 -> {:error, :invalid_request}
      true -> {:ok, body}
    end
  end

  defp required_body(_), do: {:error, :invalid_request}

  defp normalize_phone(value) when is_binary(value) do
    stripped =
      value
      |> String.trim()
      |> String.replace(~r/^whatsapp:/i, "")

    case Phone.normalize(stripped) do
      {:ok, e164} -> {:ok, e164}
      :error -> {:error, :invalid_phone}
    end
  end

  defp normalize_phone(_), do: {:error, :invalid_phone}

  defp whatsapp_address(e164) do
    e164 = digits_only(e164)
    if String.starts_with?(e164, "whatsapp:"), do: e164, else: "whatsapp:" <> e164
  end

  defp digits_only(value) do
    value
    |> to_string()
    |> String.replace(~r/^whatsapp:/i, "")
    |> String.trim()
  end

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(error) do
    Logger.error("Direct admin whatsapp database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
