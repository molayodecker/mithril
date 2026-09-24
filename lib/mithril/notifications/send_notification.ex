defmodule Mithril.Notifications.SendNotification do
  @moduledoc false

  require Logger

  alias Mithril.Notifications

  def configured? do
    present?(url()) and present?(token())
  end

  @spec invoke_mobile(map()) :: {:ok, map()} | {:error, term()}
  def invoke_mobile(body) when is_map(body) do
    if configured?() do
      case deliver_raw(body) do
        {:ok, response} -> {:ok, response}
        {:error, status, response} -> {:error, {:status, status, response}}
      end
    else
      {:error, {:status, 500, %{error: "Server misconfigured"}}}
    end
  end

  def deliver(ctx) when is_map(ctx) do
    case ctx[:recipient] do
      :customer ->
        deliver_party(ctx, :customer)

      :worker ->
        deliver_party(ctx, :worker)

      _ ->
        customer_sent = deliver_party(ctx, :customer)
        worker_sent = deliver_party(ctx, :worker)
        customer_sent or worker_sent
    end
  end

  defp deliver_party(ctx, :customer) do
    {template, message_type} = template_for(ctx[:kind], :customer)

    post_party(
      ctx[:customer],
      template,
      customer_variables(ctx),
      ctx[:booking_id] || ctx[:request_id],
      message_type
    )
  end

  defp deliver_party(ctx, :worker) do
    {template, message_type} = template_for(ctx[:kind], :worker)

    post_party(
      ctx[:worker],
      template,
      worker_variables(ctx),
      ctx[:booking_id] || ctx[:request_id],
      message_type
    )
  end

  @doc false
  def template_for(:booking_reminder, :customer),
    do: {"booking_reminder", "direct_customer_reminder"}

  def template_for(:booking_reminder, :worker),
    do: {"booking_reminder", "direct_worker_reminder"}

  def template_for(:admin_receipt, :customer),
    do: {"payment_received", "direct_admin_receipt"}

  def template_for(:admin_notify_cleaner, :worker),
    do: {"booking_reminder", "direct_admin_cleaner_reminder"}

  def template_for(_kind, :customer), do: {"cleaner_assigned", "direct_customer"}
  def template_for(_kind, :worker), do: {"new_booking", "direct_worker"}

  defp customer_variables(ctx) do
    worker = party_name(ctx[:worker], "Your cleaner")
    summary = Notifications.visit_summary(ctx)

    %{
      "name" => party_name(ctx[:customer], "there"),
      "cleanerName" => worker,
      "rating" => "Not rated yet",
      "bookingId" => ctx[:booking_id] || ctx[:request_id] || "",
      "date" => summary,
      "address" => ctx[:address] || "",
      "scheduled_date" => first_date(ctx),
      "scheduled_time" => ctx[:scheduled_time] || "",
      "paymentUrl" => Notifications.payment_url(ctx[:booking_id]),
      "payUrl" => Notifications.payment_url(ctx[:booking_id]),
      "amount" => format_amount(ctx[:amount_minor], ctx[:currency]),
      "recipientType" => "customer",
      "includeValuablesNotice" => "true"
    }
  end

  defp worker_variables(ctx) do
    summary = Notifications.visit_summary(ctx)

    %{
      "name" => party_name(ctx[:worker], "there"),
      "bookingId" => ctx[:booking_id] || ctx[:request_id] || "",
      "date" => summary,
      "address" => ctx[:address] || "",
      "customerName" => party_name(ctx[:customer], "a customer"),
      "service" => ctx[:service_name] || ctx[:role] || "Instaclean booking",
      "scheduled_date" => first_date(ctx),
      "scheduled_time" => ctx[:scheduled_time] || "",
      "recipientType" => "cleaner"
    }
  end

  defp post_party(nil, _template, _variables, _booking_id, _message_type), do: false

  defp post_party(party, template, variables, booking_id, message_type) do
    email = present(party[:email] || party["email"])
    phone = present(party[:phone] || party["phone"])
    user_id = party[:user_id] || party["user_id"]

    cond do
      is_nil(email) and is_nil(phone) ->
        false

      true ->
        channel = notify_channel(email, phone)

        transport =
          post(%{
            "template" => template,
            "channel" => channel,
            "messageType" => message_type,
            "smsFallbackToWhatsapp" => false,
            "variables" => variables,
            "bookingId" => booking_id,
            "userId" => user_id,
            "email" => email,
            "phone" => phone
          })

        whatsapp =
          if phone do
            post(%{
              "template" => template,
              "channel" => "whatsapp",
              "messageType" => message_type <> "_whatsapp",
              "variables" => variables,
              "bookingId" => booking_id,
              "userId" => user_id,
              "phone" => phone
            })
          else
            false
          end

        transport or whatsapp
    end
  end

  defp post(body) do
    case deliver_raw(body) do
      {:ok, response} -> delivered?(response)
      {:error, _, _} -> false
    end
  end

  defp deliver_raw(body) when is_map(body) do
    payload =
      body
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    case Req.post(url(), json: payload, auth: {:bearer, token()}) do
      {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
        {:ok, response}

      {:ok, %{status: status, body: response}} when is_map(response) ->
        {:error, status, response}

      {:ok, %{status: status, body: response}} ->
        {:error, status, %{"error" => inspect(response)}}

      {:error, error} ->
        Logger.warning("send-notification unavailable: #{inspect(error)}")
        {:error, 502, %{"error" => "send-notification unavailable"}}
    end
  end

  defp delivered?(body) when is_map(body) do
    truthy?(body["emailSent"]) or truthy?(body["smsSent"]) or truthy?(body["whatsappSent"]) or
      truthy?(body[:emailSent]) or truthy?(body[:smsSent]) or truthy?(body[:whatsappSent])
  end

  defp notify_channel(email, phone) do
    cond do
      email && phone -> "both"
      email -> "email"
      true -> "sms"
    end
  end

  defp party_name(nil, fallback), do: fallback

  defp party_name(party, fallback) do
    present(party[:name] || party["name"]) || fallback
  end

  defp format_amount(amount, currency) when is_integer(amount) do
    code = present(currency) || "GHS"
    "#{code} #{:erlang.float_to_binary(amount / 100, decimals: 2)}"
  end

  defp format_amount(_amount, currency), do: present(currency) || "GHS"

  defp first_date(ctx) do
    case List.wrap(ctx[:dates]) do
      [date | _] when is_binary(date) -> date
      _ -> ""
    end
  end

  defp url, do: Application.get_env(:mithril, :send_notification_url)

  defp token, do: Application.get_env(:mithril, :send_notification_token)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
