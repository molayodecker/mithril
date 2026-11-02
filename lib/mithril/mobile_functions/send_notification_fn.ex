defmodule Mithril.MobileFunctions.SendNotificationFn do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.Notifications.Outbound
  alias Mithril.Notifications.Templates
  alias Mithril.Repo
  alias Mithril.SupportOps

  @invite_templates ~w(co_cleaner_invite preferred_cleaner_invite)
  @own_contact_templates ~w(cleaner_application_submitted payout_name_mismatch_user)
  @allowed @invite_templates ++ @own_contact_templates ++ ["payout_name_mismatch_report"]

  @spec call(String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_map(body), do: call(user_id, body, &authorize/3)

  @doc false
  def call(user_id, body, authorize)
      when is_map(body) and is_function(authorize, 3) do
    template = present(body["template"])

    cond do
      not is_binary(user_id) or user_id == "" ->
        {:error, :forbidden}

      template == nil or template not in @allowed or Templates.subject(template) == nil ->
        {:error, :forbidden}

      true ->
        case authorize.(user_id, template, body) do
          {:ok, delivery} -> {:ok, deliver(template, delivery)}
          :error -> {:error, :forbidden}
        end
    end
  end

  defp deliver("payout_name_mismatch_report", body) do
    text = Templates.body("payout_name_mismatch_report", variables(body))

    result =
      SupportOps.notify(%{
        subject: Templates.subject("payout_name_mismatch_report"),
        plain_body: text
      })

    %{"emailSent" => result.email_sent, "smsSent" => false, "whatsappSent" => false}
  end

  defp deliver(_template, body) do
    Outbound.deliver(%{
      "template" => present(body["template"]),
      "channel" => present(body["channel"]) || "email",
      "email" => present(body["email"]),
      "phone" => present(body["phone"]),
      "variables" => variables(body),
      "smsFallbackToWhatsapp" => body["smsFallbackToWhatsapp"]
    })
  end

  defp authorize(user_id, template, body) when template in @invite_templates do
    table =
      if template == "co_cleaner_invite",
        do: "co_cleaner_invitations",
        else: "preferred_cleaner_invitations"

    email = downcase(body["email"])
    phone = present(body["phone"])
    invite_url = present(variables(body)["inviteUrl"]) || ""

    with {:ok, user_uuid} <- dump_user(user_id),
         {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT token::text
             FROM public.#{table}
             WHERE inviter_user_id = $1::uuid
               AND status = 'pending'
               AND expires_at > now()
               AND (
                 ($2 <> '' AND lower(coalesce(invitee_email, '')) = $2)
                 OR ($3 <> '' AND coalesce(invitee_phone_e164, '') = $3)
               )
             ORDER BY created_at DESC
             LIMIT 5
             """,
             [user_uuid, email || "", phone || ""]
           ) do
      if Enum.any?(rows, fn [token] ->
           is_binary(token) and String.contains?(invite_url, token)
         end) do
        {:ok, body}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp authorize(user_id, "payout_name_mismatch_report", body) do
    case own_contact(user_id) do
      {:ok, _contact} ->
        variables = Map.put(variables(body), "userId", user_id)
        {:ok, Map.put(body, "variables", variables)}

      :error ->
        :error
    end
  end

  defp authorize(user_id, template, body) when template in @own_contact_templates do
    case own_contact(user_id) do
      {:ok, contact} ->
        if recipient_matches?(body, contact), do: {:ok, body}, else: :error

      :error ->
        :error
    end
  end

  defp authorize(_user_id, _template, _body), do: :error

  defp recipient_matches?(body, contact) do
    email = downcase(body["email"])
    phone = present(body["phone"])
    email_ok = is_nil(email) or email == contact.email
    phone_ok = is_nil(phone) or phone == contact.phone
    (email != nil or phone != nil) and email_ok and phone_ok
  end

  defp own_contact(user_id) do
    with {:ok, user_uuid} <- dump_user(user_id),
         {:ok, %{rows: [[email, phone]]}} <-
           Repo.query(
             "SELECT email, phone FROM public.users WHERE id = $1::uuid LIMIT 1",
             [user_uuid]
           ) do
      {:ok, %{email: downcase(email), phone: present(phone)}}
    else
      _ -> :error
    end
  end

  defp variables(body) do
    case body["variables"] do
      values when is_map(values) ->
        values
        |> Enum.flat_map(fn {key, value} ->
          key = to_string(key)

          cond do
            not Regex.match?(~r/^[A-Za-z][A-Za-z0-9]{0,40}$/, key) ->
              []

            is_binary(value) ->
              [{key, String.slice(String.trim(value), 0, 500)}]

            true ->
              []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp dump_user(user_id) do
    {:ok, DbUuid.dump!(user_id)}
  rescue
    ArgumentError -> :error
  end

  defp downcase(value) do
    case present(value) do
      nil -> nil
      text -> String.downcase(text)
    end
  end

  defp present(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present(_value), do: nil
end
