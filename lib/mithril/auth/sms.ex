defmodule Mithril.Auth.SMS do
  @moduledoc false

  @callback send_otp(String.t(), String.t()) :: :ok | {:error, atom()}

  def send_otp(phone, code) when is_binary(phone) and is_binary(code) do
    adapter().send_otp(phone, code)
  end

  def configured? do
    adapter() != Mithril.Auth.SMS.Disabled
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
    from = Application.get_env(:mithril, :twilio_from_number)

    if is_binary(sid) and sid != "" and is_binary(token) and token != "" and is_binary(from) and
         from != "" do
      url = "https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json"

      body = [
        To: phone,
        From: from,
        Body: "Your Instaclean code is #{code}. It expires in 5 minutes."
      ]

      case Req.post(url, form: body, auth: {:basic, "#{sid}:#{token}"}) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, _} -> {:error, :sms_delivery_failed}
        {:error, _} -> {:error, :sms_delivery_failed}
      end
    else
      {:error, :sms_not_configured}
    end
  end
end
