defmodule Mithril.Auth.TestPhones do
  @moduledoc false

  alias Mithril.Auth.Phone

  def lookup(phone) when is_binary(phone), do: Map.get(table(), phone)
  def lookup(_), do: nil

  def configured?(phone) when is_binary(phone), do: Map.has_key?(table(), phone)
  def configured?(_), do: false

  def any?, do: table() != %{}

  def parse(nil), do: %{}
  def parse(""), do: %{}

  def parse(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, &parse_pair/2)
  end

  defp parse_pair(pair, acc) do
    case String.split(pair, ":", parts: 2) do
      [phone, code] ->
        phone = String.trim(phone)
        code = String.trim(code)

        case {Phone.normalize(phone), otp_shape?(code)} do
          {{:ok, e164}, true} ->
            Map.put(acc, e164, code)

          _ ->
            raise ArgumentError,
                  "AUTH_TEST_PHONES entries must be phone:otp, got: #{inspect(pair)}"
        end

      _ ->
        raise ArgumentError, "AUTH_TEST_PHONES entries must be phone:otp, got: #{inspect(pair)}"
    end
  end

  defp otp_shape?(code), do: String.match?(code, ~r/^\d{4,8}$/)

  defp table, do: Application.get_env(:mithril, :sms_test_phones, %{})
end
