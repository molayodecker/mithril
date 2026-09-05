defmodule Mithril.Auth.OAuthTest do
  use ExUnit.Case, async: false

  alias Mithril.Auth.OAuth

  setup do
    previous = Application.get_env(:mithril, :auth_http)

    Application.put_env(:mithril, :auth_http, fn url ->
      cond do
        String.contains?(url, "oauth2.googleapis.com") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "sub" => "google-sub-1",
               "aud" => "test-google-client",
               "email" => "Google@Example.com",
               "email_verified" => true,
               "name" => "Google User"
             }
           }}

        String.contains?(url, "debug_token") ->
          {:ok,
           %{
             status: 200,
             body: %{"data" => %{"is_valid" => true, "app_id" => "test-facebook-app"}}
           }}

        String.contains?(url, "graph.facebook.com/me") ->
          {:ok,
           %{
             status: 200,
             body: %{"id" => "facebook-1", "email" => "fb@example.com", "name" => "FB"}
           }}
      end
    end)

    on_exit(fn ->
      if previous do
        Application.put_env(:mithril, :auth_http, previous)
      else
        Application.delete_env(:mithril, :auth_http)
      end
    end)

    :ok
  end

  test "verifies a Google id_token audience and verified email" do
    assert {:ok, identity} = OAuth.verify_google("id-token")
    assert identity.provider == "google"
    assert identity.subject == "google-sub-1"
    assert identity.email == "google@example.com"
  end

  test "accepts tokeninfo string true for Google email verification" do
    put_google_response(%{
      "sub" => "google-sub-string",
      "aud" => "test-google-client",
      "email" => "string@example.com",
      "email_verified" => "true"
    })

    assert {:ok, identity} = OAuth.verify_google("id-token")
    assert identity.email == "string@example.com"
  end

  test "does not expose an unverified Google email for account linking" do
    put_google_response(%{
      "sub" => "google-sub-unverified",
      "aud" => "test-google-client",
      "email" => "victim@example.com",
      "email_verified" => false
    })

    assert {:ok, identity} = OAuth.verify_google("id-token")
    assert identity.subject == "google-sub-unverified"
    assert identity.email == nil
  end

  test "does not expose a Google email when email_verified is missing" do
    put_google_response(%{
      "sub" => "google-sub-missing",
      "aud" => "test-google-client",
      "email" => "victim@example.com"
    })

    assert {:ok, identity} = OAuth.verify_google("id-token")
    assert identity.subject == "google-sub-missing"
    assert identity.email == nil
  end

  test "verifies a Facebook access token" do
    assert {:ok, identity} = OAuth.verify_facebook("access-token")
    assert identity.provider == "facebook"
    assert identity.subject == "facebook-1"
  end

  test "Facebook is disabled unless both app id and app secret are configured" do
    previous_secret = Application.get_env(:mithril, :facebook_app_secret)
    Application.delete_env(:mithril, :facebook_app_secret)

    on_exit(fn ->
      if previous_secret do
        Application.put_env(:mithril, :facebook_app_secret, previous_secret)
      else
        Application.delete_env(:mithril, :facebook_app_secret)
      end
    end)

    refute OAuth.facebook_configured?()
    assert {:error, :oauth_not_configured} = OAuth.verify_facebook("access-token")
  end

  test "rejects an empty Google token" do
    assert {:error, :invalid_oauth_token} = OAuth.verify_google("")
  end

  defp put_google_response(body) do
    Application.put_env(:mithril, :auth_http, fn _url ->
      {:ok, %{status: 200, body: body}}
    end)
  end
end
