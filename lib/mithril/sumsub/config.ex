defmodule Mithril.Sumsub.Config do
  @moduledoc false

  @default_level "id-and-liveness"

  def credentials do
    app_token = Application.get_env(:mithril, :sumsub_app_token)
    secret_key = Application.get_env(:mithril, :sumsub_secret_key)

    if present?(app_token) and present?(secret_key) do
      {:ok, %{app_token: String.trim(app_token), secret_key: String.trim(secret_key)}}
    else
      {:error, :missing_credentials}
    end
  end

  def level_name do
    Application.get_env(:mithril, :sumsub_level_name, @default_level)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @default_level
      level -> level
    end
  end

  def country_code do
    Application.get_env(:mithril, :sumsub_default_country, "GHA")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "GHA"
      code -> code
    end
  end

  def nationality_code do
    Application.get_env(:mithril, :sumsub_default_nationality, "GHA")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "GHA"
      code -> code
    end
  end

  def base_url do
    Application.get_env(:mithril, :sumsub_base_url, "https://api.sumsub.com")
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
