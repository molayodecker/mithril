defmodule Mithril.Auth.OAuth do
  @moduledoc false

  def verify_google(id_token) when is_binary(id_token) and id_token != "" do
    client_ids = allowed_google_client_ids()

    if client_ids == [] do
      {:error, :oauth_not_configured}
    else
      url = "https://oauth2.googleapis.com/tokeninfo?id_token=#{URI.encode_www_form(id_token)}"

      with {:ok, body} <- get_json(url),
           {:ok, sub} <- required_string(body, "sub"),
           :ok <- assert_audience(body["aud"], client_ids) do
        {:ok,
         %{
           provider: "google",
           subject: sub,
           email: optional_email(body["email"]),
           name: optional_string(body["name"])
         }}
      else
        {:error, :oauth_not_configured} -> {:error, :oauth_not_configured}
        _other -> {:error, :invalid_oauth_token}
      end
    end
  end

  def verify_google(_), do: {:error, :invalid_oauth_token}

  def verify_facebook(access_token) when is_binary(access_token) and access_token != "" do
    app_id = Application.get_env(:mithril, :facebook_app_id)
    app_secret = Application.get_env(:mithril, :facebook_app_secret)

    cond do
      not is_binary(app_id) or app_id == "" ->
        {:error, :oauth_not_configured}

      true ->
        with :ok <- maybe_debug_facebook(access_token, app_id, app_secret),
             {:ok, body} <-
               get_json(
                 "https://graph.facebook.com/me?fields=id,email,name&access_token=#{URI.encode_www_form(access_token)}"
               ),
             {:ok, subject} <- required_string(body, "id") do
          {:ok,
           %{
             provider: "facebook",
             subject: subject,
             email: optional_email(body["email"]),
             name: optional_string(body["name"])
           }}
        else
          {:error, :oauth_not_configured} -> {:error, :oauth_not_configured}
          _other -> {:error, :invalid_oauth_token}
        end
    end
  end

  def verify_facebook(_), do: {:error, :invalid_oauth_token}

  def google_configured?, do: allowed_google_client_ids() != []

  def facebook_configured? do
    app_id = Application.get_env(:mithril, :facebook_app_id)
    is_binary(app_id) and app_id != ""
  end

  defp maybe_debug_facebook(_token, _app_id, secret) when secret in [nil, ""], do: :ok

  defp maybe_debug_facebook(access_token, app_id, app_secret) do
    app_token = "#{app_id}|#{app_secret}"

    url =
      "https://graph.facebook.com/debug_token?input_token=#{URI.encode_www_form(access_token)}&access_token=#{URI.encode_www_form(app_token)}"

    case get_json(url) do
      {:ok, %{"data" => data}} ->
        if data["is_valid"] == true and to_string(data["app_id"] || "") == app_id do
          :ok
        else
          {:error, :invalid_oauth_token}
        end

      _other ->
        {:error, :invalid_oauth_token}
    end
  end

  defp allowed_google_client_ids do
    Application.get_env(:mithril, :google_client_ids, [])
    |> List.wrap()
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp assert_audience(aud, allowed) when is_binary(aud) do
    if aud in allowed, do: :ok, else: {:error, :invalid_oauth_token}
  end

  defp assert_audience(_, _), do: {:error, :invalid_oauth_token}

  defp get_json(url) do
    client = Application.get_env(:mithril, :auth_http, &default_get/1)

    case client.(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} when is_binary(body) -> Jason.decode(body)
      _other -> {:error, :invalid_oauth_token}
    end
  end

  defp default_get(url) do
    Req.get(url, decode_json: [keys: :strings])
  end

  defp required_string(map, key) do
    case optional_string(map[key]) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp optional_email(value) do
    case optional_string(value) do
      nil -> nil
      email -> String.downcase(email)
    end
  end

  defp optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional_string(_), do: nil
end
