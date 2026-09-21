defmodule MithrilWeb.CacheBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, maybe_cache(conn, body)}

      {:more, body, conn} ->
        {:more, body, maybe_cache(conn, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def body(conn) do
    conn.assigns
    |> Map.get(:raw_body, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp maybe_cache(%Plug.Conn{path_info: ["webhooks", name]} = conn, body)
       when name in ["paystack", "sumsub"] do
    update_in(conn.assigns[:raw_body], &[body | &1 || []])
  end

  defp maybe_cache(conn, _body), do: conn
end
