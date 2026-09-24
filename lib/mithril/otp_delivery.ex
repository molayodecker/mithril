defmodule Mithril.OtpDelivery do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.SecretCrypto

  @phone_otp_message_type "phone_otp"

  @spec fetch_token_for_phone(String.t()) ::
          {:ok, map()}
          | {:error, {:status, non_neg_integer(), map()}}
  def fetch_token_for_phone(phone) when is_binary(phone) do
    normalized = String.trim(phone)

    if normalized == "" do
      {:error, {:status, 400, %{error: "Phone is required.", error_code: "unknown"}}}
    else
      case load_active_group_by_phone(normalized) do
        nil ->
          {:error,
           {:status, 404,
            %{
              error: "No active verification delivery found.",
              error_code: "not_ready",
              channels: %{whatsapp: false, email: false}
            }}}

        group ->
          channels = resolve_channels(Map.get(group, "user_id"))
          expires_at = Map.get(group, "expires_at")

          if expired?(expires_at) do
            {:error,
             {:status, 410,
              %{
                error: "Verification delivery expired.",
                error_code: "expired",
                channels: channels
              }}}
          else
            case Map.get(group, "delivery_token_ciphertext") do
              ciphertext when is_binary(ciphertext) and ciphertext != "" ->
                case SecretCrypto.decrypt(ciphertext) do
                  {:ok, delivery_token} ->
                    mark_client_fetched(
                      Map.get(group, "id"),
                      Map.get(group, "client_token_fetched_at")
                    )

                    {:ok, %{delivery_token: delivery_token, channels: channels}}

                  {:error, _} ->
                    {:error,
                     {:status, 500,
                      %{
                        error: "Delivery token could not be decrypted.",
                        error_code: "configuration_error",
                        channels: channels
                      }}}
                end

              _ ->
                {:error,
                 {:status, 500,
                  %{
                    error: "Delivery token unavailable.",
                    error_code: "configuration_error",
                    channels: channels
                  }}}
            end
          end
      end
    end
  end

  @spec resend_via_channel(String.t(), String.t()) ::
          {:ok, map()} | {:error, {:status, non_neg_integer(), map()}}
  def resend_via_channel(delivery_token, channel)
      when is_binary(delivery_token) and channel in ["whatsapp", "email"] do
    token = String.trim(delivery_token)

    if token == "" do
      {:error, {:status, 400, %{error: "Delivery token is required."}}}
    else
      token_hash = SecretCrypto.hash_token(token)

      case load_active_group_by_token_hash(token_hash) do
        nil ->
          {:error, {:status, 400, %{error: "Invalid or expired delivery token."}}}

        group ->
          case SecretCrypto.decrypt(Map.get(group, "otp_ciphertext") || "") do
            {:ok, otp} ->
              if channel == "email" do
                send_email_resend(group, otp)
              else
                send_whatsapp_resend(group, otp)
              end

            _ ->
              {:error, {:status, 400, %{error: "Could not load verification code."}}}
          end
      end
    end
  end

  def resend_via_channel(_delivery_token, _channel) do
    {:error, {:status, 400, %{error: "Invalid channel."}}}
  end

  defp send_email_resend(group, otp) do
    user_id = Map.get(group, "user_id")

    with email when is_binary(email) <- fetch_verified_email(user_id),
         :ok <- send_resend_email(email, otp) do
      {:ok, %{ok: true}}
    else
      nil ->
        {:error,
         {:status, 400, %{error: "Add and verify an email in Settings to use email delivery."}}}

      {:error, message} ->
        {:error, {:status, 400, %{error: message}}}
    end
  end

  defp send_whatsapp_resend(group, otp) do
    phone = Map.get(group, "to_phone")

    case Mithril.Auth.SMS.send_message(
           phone,
           "Your Instaclean verification code is #{otp}. Do not share this code."
         ) do
      :ok ->
        {:ok, %{ok: true}}

      {:error, _} ->
        {:error,
         {:status, 400, %{error: "Could not send code via WhatsApp. Try SMS or email instead."}}}
    end
  end

  defp send_resend_email(email, otp) do
    api_key = Application.get_env(:mithril, :resend_api_key, "") |> to_string() |> String.trim()

    if api_key == "" do
      {:error, "Could not send code via email. Try SMS or WhatsApp."}
    else
      from =
        Application.get_env(
          :mithril,
          :resend_from,
          "Instaclean <noreply@update.tryinstaclean.com>"
        )

      body = %{
        from: from,
        to: [email],
        subject: "Your Instaclean verification code",
        html: """
        <p>Use this code to sign in to Instaclean:</p>
        <p><strong>#{otp}</strong></p>
        """
      }

      case Req.post("https://api.resend.com/emails",
             json: body,
             auth: {:bearer, api_key}
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _ -> {:error, "Could not send code via email. Try SMS or WhatsApp."}
      end
    end
  end

  defp load_active_group_by_phone(phone) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    sql = """
    SELECT *
    FROM public.message_delivery_groups
    WHERE to_phone = $1
      AND message_type = $2
      AND superseded_at IS NULL
      AND consumed_at IS NULL
      AND expires_at > $3::timestamptz
    ORDER BY created_at DESC
    LIMIT 1
    """

    query_one(sql, [phone, @phone_otp_message_type, now])
  end

  defp load_active_group_by_token_hash(token_hash) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    sql = """
    SELECT *
    FROM public.message_delivery_groups
    WHERE delivery_token_hash = $1
      AND superseded_at IS NULL
      AND consumed_at IS NULL
      AND expires_at > $2::timestamptz
    LIMIT 1
    """

    query_one(sql, [token_hash, now])
  end

  defp mark_client_fetched(group_id, fetched_at) do
    if is_nil(fetched_at) and present?(group_id) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      _ =
        Repo.query(
          "UPDATE public.message_delivery_groups SET client_token_fetched_at = $1::timestamptz WHERE id = $2::uuid",
          [now, group_id]
        )
    end

    :ok
  end

  defp resolve_channels(nil), do: %{whatsapp: true, email: false}

  defp resolve_channels(user_id) do
    email = if fetch_verified_email(user_id), do: true, else: false
    %{whatsapp: true, email: email}
  end

  defp fetch_verified_email(user_id) when is_binary(user_id) do
    sql = """
    SELECT email
    FROM public.users
    WHERE id = $1::uuid AND contact_email_verified_at IS NOT NULL
    LIMIT 1
    """

    case Repo.query(sql, [user_id]) do
      {:ok, %{rows: [[email]]}} when is_binary(email) ->
        trimmed = String.trim(email)

        if trimmed != "" and
             not String.ends_with?(String.downcase(trimmed), "@phone.tryinstaclean.local") do
          trimmed
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp fetch_verified_email(_), do: nil

  defp expired?(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _} -> DateTime.compare(datetime, DateTime.utc_now()) != :gt
      _ -> true
    end
  end

  defp expired?(_), do: true

  defp query_one(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{columns: columns, rows: [row]}} -> Map.new(Enum.zip(columns, row))
      _ -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
