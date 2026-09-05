defmodule Mithril.Auth.TestPhonesTest do
  use ExUnit.Case, async: true

  alias Mithril.Auth.TestPhones

  test "parses comma-separated phone:otp pairs into E.164 keys" do
    assert TestPhones.parse("+15555550100:123456, 0555000000:000000") == %{
             "+15555550100" => "123456",
             "+233555000000" => "000000"
           }
  end

  test "treats blank input as no test phones" do
    assert TestPhones.parse(nil) == %{}
    assert TestPhones.parse("") == %{}
  end

  test "rejects malformed pairs" do
    assert_raise ArgumentError, fn -> TestPhones.parse("not-a-phone:123456") end
    assert_raise ArgumentError, fn -> TestPhones.parse("+15555550100:abc") end
    assert_raise ArgumentError, fn -> TestPhones.parse("+15555550100") end
  end
end
