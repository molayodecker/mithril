defmodule MithrilWeb.Plugs.Pay2OwnAuth do
  @moduledoc """
  Protects the Pay2Own worker lookup. Pay2Own sends `x-pay2own-token`.
  Local development accepts `pay2own-local-dev` when no token is configured.
  """

  import Plug.Conn

  @header "x-pay2own-token"
  @dev_fallback if(Mix.env() == :dev, do: "pay2own-local-dev", else: "")

  def init(opts), do: opts

  def call(conn, _opts) do
    configured = configured_token()
    supplied = conn |> get_req_header(@header) |> List.first()

    cond do
      configured == "" ->
        reject(conn, 503, "not_configured")

      valid_token?(configured, supplied) ->
        conn

      true ->
        reject(conn, 401, "unauthorized")
    end
  end

  defp configured_token do
    case Application.get_env(:mithril, :pay2own_intake_token) do
      token when is_binary(token) and token != "" -> token
      _ -> @dev_fallback
    end
  end

  defp valid_token?(configured, supplied)
       when is_binary(supplied) and byte_size(configured) == byte_size(supplied) do
    Plug.Crypto.secure_compare(configured, supplied)
  end

  defp valid_token?(_, _), do: false

  defp reject(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
