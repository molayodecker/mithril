defmodule Mithril.WhatsApp.PaymentTemplate do
  @moduledoc """
  WhatsApp template that gives a customer a public payment link.

  The button URL is `{DIRECT_PUBLIC_URL}/pay/{{4}}`, where `{{4}}` is the
  unguessable token. The page does not require a sign-in.

  Set `TWILIO_TEMPLATE_PAYMENT_REQUEST` to an approved Twilio Content SID to
  use that template. When it is unset, the first send creates
  `instaclean_tap_to_pay` and submits it for WhatsApp approval.
  The body keeps words after the last variable, and the button is a URL
  action titled "Tap Here to Pay". WhatsApp draws that as the green
  link row under the message.
  Meta approval is not instant. Until the template can be sent, the payment
  request is delivered by SMS instead.
  """

  require Logger

  alias Mithril.Repo

  @name "instaclean_tap_to_pay"
  @button "Tap Here to Pay"

  def name, do: @name

  def body do
    "Hello {{1}}, Instaclean is requesting {{2}} for {{3}}. Tap below to pay."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{
        "1" => "Ama",
        "2" => "GHS 150.00",
        "3" => "Home clean",
        "4" => "a1b2c3d4e5f6789012345678abcdef0123456789abcdef0123456789abcdef01"
      },
      "types" => %{
        "twilio/call-to-action" => %{
          "body" => body(),
          "actions" => [
            %{
              "type" => "URL",
              "title" => @button,
              "url" => "#{public_base()}/pay/{{4}}"
            }
          ]
        }
      }
    }
  end

  def variables(%{
        "customerName" => name,
        "description" => description,
        "amountLabel" => amount,
        "publicToken" => token
      }) do
    %{
      "1" => clip(name, 60, "Customer"),
      "2" => clip(amount, 40, "your bill"),
      "3" => clip(description, 80, "Instaclean"),
      "4" => token
    }
  end

  def content_sid do
    env_sid() || stored_sid()
  end

  def ensure do
    case env_sid() do
      sid when is_binary(sid) and sid != "" -> {:ok, sid}
      _ -> ensure_stored()
    end
  end

  defp ensure_stored do
    case stored_template() do
      {sid, "submitted"} when is_binary(sid) -> {:ok, sid}
      {sid, _status} when is_binary(sid) -> approve_and_mark(sid)
      _ -> create()
    end
  end

  defp create do
    case request_create(definition()) do
      {:ok, sid} ->
        _ = store_sid(sid)
        approve_and_mark(sid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp approve_and_mark(sid) do
    case request_approval(sid) do
      :ok -> mark_submitted(sid)
      {:ok, _} -> mark_submitted(sid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_submitted(sid) do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             """
             UPDATE public.whatsapp_content_templates
             SET approval_status = 'submitted', updated_at = now()
             WHERE name = $1 AND content_sid = $2
             """,
             [@name, sid]
           ) do
        {:ok, _} -> {:ok, sid}
        {:error, _} -> {:error, :template_not_created}
      end
    else
      {:ok, sid}
    end
  end

  defp request_create(payload) do
    case Application.get_env(:mithril, :twilio_content_http, :http) do
      fun when is_function(fun, 2) ->
        fun.(:create, payload)

      _ ->
        post_content("https://content.twilio.com/v1/Content", payload)
    end
  end

  defp request_approval(sid) do
    body = %{"name" => @name, "category" => "UTILITY"}

    case Application.get_env(:mithril, :twilio_content_http, :http) do
      fun when is_function(fun, 2) ->
        fun.(:approve, body)

      _ ->
        post_content(
          "https://content.twilio.com/v1/Content/#{sid}/ApprovalRequests/whatsapp",
          body
        )
    end
  end

  defp post_content(url, payload) do
    with {:ok, env} <- twilio_env() do
      case Req.post(url, json: payload, auth: {:basic, "#{env.sid}:#{env.token}"}) do
        {:ok, %{status: status, body: %{"sid" => sid}}}
        when status in 200..299 and is_binary(sid) ->
          {:ok, sid}

        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "whatsapp payment template request failed status=#{status} body=#{inspect(body)}"
          )

          {:error, :template_not_created}

        {:error, error} ->
          Logger.warning("whatsapp payment template request failed #{inspect(error)}")
          {:error, :template_not_created}
      end
    end
  end

  defp twilio_env do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)

    if is_binary(sid) and sid != "" and is_binary(token) and token != "" do
      {:ok, %{sid: sid, token: token}}
    else
      {:error, :twilio_not_configured}
    end
  end

  defp env_sid do
    case Application.get_env(:mithril, :twilio_template_payment_request) do
      sid when is_binary(sid) ->
        sid = String.trim(sid)
        if sid == "", do: nil, else: sid

      _ ->
        nil
    end
  end

  defp stored_sid do
    case stored_template() do
      {sid, _} -> sid
      _ -> nil
    end
  end

  defp stored_template do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             "SELECT content_sid, approval_status FROM public.whatsapp_content_templates WHERE name = $1",
             [@name]
           ) do
        {:ok, %{rows: [[sid, status]]}} when is_binary(sid) and sid != "" -> {sid, status}
        _ -> nil
      end
    else
      nil
    end
  end

  defp store_sid(sid) do
    if table?("public.whatsapp_content_templates") do
      Repo.query(
        """
        INSERT INTO public.whatsapp_content_templates (name, content_sid, approval_status)
        VALUES ($1, $2, 'created')
        ON CONFLICT (name) DO UPDATE
          SET content_sid = EXCLUDED.content_sid,
              approval_status = 'created', updated_at = now()
        """,
        [@name, sid]
      )
    else
      :ok
    end
  end

  defp table?(name) do
    case Repo.query("SELECT to_regclass($1)::text", [name]) do
      {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  def public_base do
    Application.get_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp clip(value, max, fallback) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/[{}]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, max)

    if cleaned == "", do: fallback, else: cleaned
  end
end
