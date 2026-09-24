defmodule Mithril.DbUuid do
  @moduledoc false

  @spec dump!(binary()) :: binary()
  def dump!(value) when is_binary(value) and byte_size(value) == 16, do: value

  def dump!(value) when is_binary(value) do
    Ecto.UUID.dump!(value)
  end

  @spec dump_all!([binary()]) :: [binary()]
  def dump_all!(values) when is_list(values), do: Enum.map(values, &dump!/1)

  @spec equal?(binary() | nil, binary() | nil) :: boolean()
  def equal?(nil, nil), do: true
  def equal?(nil, _), do: false
  def equal?(_, nil), do: false
  def equal?(left, right), do: dump!(left) == dump!(right)

  @spec encode(binary() | nil) :: String.t() | nil
  def encode(nil), do: nil

  def encode(value) when is_binary(value) and byte_size(value) == 16 do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "invalid database UUID"
    end
  end

  def encode(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> raise ArgumentError, "invalid UUID"
    end
  end
end
