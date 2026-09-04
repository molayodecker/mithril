defmodule Mithril.Auth.Token do
  @moduledoc false

  use Joken.Config

  def token_config do
    default_claims(iss: "mithril", default_exp: access_ttl())
    |> add_claim("typ", fn -> "access" end, &(&1 == "access"))
  end

  def issue(user_id, email) when is_binary(user_id) and is_binary(email) do
    extra = %{"sub" => user_id, "email" => email}
    generate_and_sign(extra, signer())
  end

  def verify_access(token) when is_binary(token) do
    verify_and_validate(token, signer())
  end

  def signer do
    Joken.Signer.create("HS256", jwt_secret())
  end

  def access_ttl do
    Application.get_env(:mithril, :auth_access_ttl, 3600)
  end

  def refresh_ttl do
    Application.get_env(:mithril, :auth_refresh_ttl, 60 * 60 * 24 * 30)
  end

  defp jwt_secret do
    Application.get_env(:mithril, :auth_jwt_secret) ||
      Keyword.fetch!(Application.fetch_env!(:mithril, MithrilWeb.Endpoint), :secret_key_base)
  end
end
