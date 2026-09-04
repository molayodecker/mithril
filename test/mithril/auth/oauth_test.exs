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

  test "verifies a Google id_token audience" do
    assert {:ok, identity} = OAuth.verify_google("id-token")
    assert identity.provider == "google"
    assert identity.subject == "google-sub-1"
    assert identity.email == "google@example.com"
  end

  test "verifies a Facebook access token" do
    assert {:ok, identity} = OAuth.verify_facebook("access-token")
    assert identity.provider == "facebook"
    assert identity.subject == "facebook-1"
  end

  test "rejects an empty Google token" do
    assert {:error, :invalid_oauth_token} = OAuth.verify_google("")
  end
end
