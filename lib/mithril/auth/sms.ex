defmodule Mithril.Auth.SMS do
  @moduledoc false

  alias Mithril.Auth.TestPhones

  @callback send_otp(String.t(), String.t()) :: :ok | {:error, atom()}

  def send_otp(phone, code) when is_binary(phone) and is_binary(code) do
    if TestPhones.configured?(phone) do
      :ok
    else
      adapter().send_otp(phone, code)
    end
  end

  def configured? do
    adapter() != Mithril.Auth.SMS.Disabled or TestPhones.any?()
  end

  def deliverable?(phone) do
    TestPhones.configured?(phone) or adapter() != Mithril.Auth.SMS.Disabled
  end

  def adapter do
    Application.get_env(:mithril, :sms_adapter, Mithril.Auth.SMS.Disabled)
  end
end

defmodule Mithril.Auth.SMS.Disabled do
  @moduledoc false
  @behaviour Mithril.Auth.SMS

  @impl true
  def send_otp(_phone, _code), do: {:error, :sms_not_configured}
end

defmodule Mithril.Auth.SMS.Test do
  @moduledoc false
  @behaviour Mithril.Auth.SMS

  @impl true
  def send_otp(phone, code) do
    Application.put_env(:mithril, :test_last_otp, {phone, code})
    :ok
  end
end

defmodule Mithril.Auth.SMS.Twilio do
  @moduledoc false
  @behaviour Mithril.Auth.SMS

  @impl true
  def send_otp(phone, code) do
    sid = Application.get_env(:mithril, :twilio_account_sid)
    token = Application.get_env(:mithril, :twilio_auth_token)
    messaging_service = Application.get_env(:mithril, :twilio_messaging_service_sid)
    from = Application.get_env(:mithril, :twilio_from_number)

    cond do
      not present?(sid) or not present?(token) ->
        {:error, :sms_not_configured}

      not present?(messaging_service) and not present?(from) ->
        {:error, :sms_not_configured}

      true ->
        url = "https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json"

        body =
          [To: phone, Body: "Your Instaclean code is #{code}. It expires in 5 minutes."]
          |> then(fn fields ->
            if present?(messaging_service) do
              Keyword.put(fields, :MessagingServiceSid, messaging_service)
            else
              Keyword.put(fields, :From, from)
            end
          end)

        case Req.post(url, form: body, auth: {:basic, "#{sid}:#{token}"}) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, _} -> {:error, :sms_delivery_failed}
          {:error, _} -> {:error, :sms_delivery_failed}
        end
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false
end
