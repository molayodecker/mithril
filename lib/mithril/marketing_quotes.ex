defmodule Mithril.MarketingQuotes do
  @moduledoc false

  alias Mithril.Notifications.Resend
  alias Mithril.WhatsApp.Recruitment.Outbound

  @business_whatsapp "whatsapp:+233559100642"
  @default_template_sid "HX6f269261c31ade38a05104965e15c256"
  @approval_ttl_ms 300_000

  def submit(params) when is_map(params) do
    if text(params, "company_website", "companyWebsite", 200) != "" do
      {:ok, :accepted}
    else
      with {:ok, quote} <- cast(params),
           :ok <- deliver_email(quote),
           :ok <- deliver_whatsapp(quote) do
        {:ok, :accepted}
      end
    end
  end

  def submit(_), do: {:error, :invalid}

  defp cast(params) do
    quote = %{
      name: text(params, "name", "name", 120),
      phone: text(params, "phone", "phone", 40),
      service: text(params, "serviceType", "service_type", 80),
      location: text(params, "location", "location", 120),
      company: text(params, "company", "company", 160),
      email: text(params, "email", "email", 160),
      frequency: text(params, "frequency", "frequency", 80),
      notes: text(params, "notes", "notes", 800)
    }

    cond do
      quote.name == "" or quote.phone == "" or quote.service == "" or quote.location == "" ->
        {:error, :invalid}

      quote.phone |> String.replace(~r/\D/, "") |> String.length() < 9 ->
        {:error, :invalid}

      true ->
        {:ok, quote}
    end
  end

  defp deliver_email(quote) do
    body = message(quote)
    to = Application.get_env(:mithril, :support_email, "support@tryinstaclean.com")

    case Resend.deliver(%{
           to: to,
           subject: "Instaclean quote request",
           text: body,
           html: "<pre style=\"font-family:sans-serif\">#{escape(body)}</pre>"
         }) do
      :ok -> :ok
      {:error, _} -> {:error, :email_failed}
    end
  end

  defp deliver_whatsapp(quote) do
    from = Application.get_env(:mithril, :twilio_whatsapp_from)
    body = message(quote)

    result =
      case approved_template_sid() do
        sid when is_binary(sid) and sid != "" ->
          case Outbound.send_content(@business_whatsapp, from, sid, template_variables(quote)) do
            {:ok, _} -> :ok
            {:error, _} -> Outbound.send_plain_text(@business_whatsapp, from, body)
          end

        _ ->
          Outbound.send_plain_text(@business_whatsapp, from, body)
      end

    case result do
      :ok -> :ok
      _ -> {:error, :whatsapp_failed}
    end
  end

  defp approved_template_sid do
    case Application.get_env(:mithril, :marketing_quote_template, :check) do
      :plain -> nil
      :approved -> template_sid()
      _ -> if template_approved?(template_sid()), do: template_sid(), else: nil
    end
  end

  defp template_sid do
    Application.get_env(:mithril, :marketing_quote_template_sid, @default_template_sid)
  end

  defp template_approved?(sid) do
    now = System.system_time(:millisecond)

    case :persistent_term.get({__MODULE__, :approval}, nil) do
      {^sid, status, at} when now - at < @approval_ttl_ms ->
        status == "approved"

      _ ->
        status = fetch_approval(sid)
        :persistent_term.put({__MODULE__, :approval}, {sid, status, now})
        status == "approved"
    end
  end

  defp fetch_approval(sid) do
    account = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)

    with account when is_binary(account) and account != "" <- account,
         token when is_binary(token) and token != "" <- token,
         {:ok, %{status: 200, body: body}} <-
           Req.get("https://content.twilio.com/v1/Content/#{sid}/ApprovalRequests",
             auth: {:basic, "#{account}:#{token}"}
           ) do
      body
      |> Map.get("whatsapp", %{})
      |> Map.get("status", "")
      |> to_string()
    else
      _ -> ""
    end
  end

  defp template_variables(quote) do
    details =
      [
        line("Company", quote.company),
        line("Email", quote.email),
        line("Frequency", quote.frequency),
        line("Notes", quote.notes)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(". ")

    %{
      "1" => variable(quote.name),
      "2" => variable(quote.phone),
      "3" => variable(quote.service),
      "4" => variable(quote.location),
      "5" => variable(details, "None")
    }
  end

  defp message(quote) do
    [
      "Instaclean quote request",
      "Name: #{quote.name}",
      line("Company or property", quote.company),
      "Phone: #{quote.phone}",
      line("Email", quote.email),
      "Service: #{quote.service}",
      "Location: #{quote.location}",
      line("Frequency", quote.frequency),
      line("Notes", quote.notes)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp line(_label, ""), do: ""
  defp line(label, value), do: "#{label}: #{value}"

  defp variable(value, fallback \\ "None") do
    cleaned =
      value
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/ {2,}/, " ")
      |> String.trim()

    cleaned = if cleaned == "", do: fallback, else: cleaned
    String.slice(cleaned, 0, 800)
  end

  defp text(params, camel, snake, max) do
    (Map.get(params, camel) || Map.get(params, snake) || "")
    |> to_string()
    |> String.trim()
    |> String.slice(0, max)
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
