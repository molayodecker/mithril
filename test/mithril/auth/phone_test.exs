defmodule Mithril.Auth.PhoneTest do
  use ExUnit.Case, async: true

  alias Mithril.Auth.Phone

  test "normalizes Ghana local numbers to E.164" do
    assert Phone.normalize("0244123456") == {:ok, "+233244123456"}
    assert Phone.normalize("233244123456") == {:ok, "+233244123456"}
    assert Phone.normalize("+233 244 123 456") == {:ok, "+233244123456"}
  end

  test "rejects emails and short values" do
    assert Phone.normalize("user@example.com") == :error
    assert Phone.normalize("123") == :error
    assert Phone.normalize(nil) == :error
  end
end
