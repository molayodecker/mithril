defmodule Mithril.Auth.TokenTest do
  use ExUnit.Case, async: true

  alias Mithril.Auth.Token

  test "issues a verifiable access JWT" do
    user_id = Ecto.UUID.generate()
    {:ok, token, claims} = Token.issue(user_id, "jwt@example.com")

    assert claims["sub"] == user_id
    assert claims["email"] == "jwt@example.com"
    assert claims["iss"] == "mithril"
    assert claims["typ"] == "access"

    assert {:ok, verified} = Token.verify_access(token)
    assert verified["sub"] == user_id
    assert verified["email"] == "jwt@example.com"
  end

  test "rejects a tampered token" do
    {:ok, token, _claims} = Token.issue(Ecto.UUID.generate(), "jwt@example.com")
    assert {:error, _reason} = Token.verify_access(token <> "x")
  end
end
