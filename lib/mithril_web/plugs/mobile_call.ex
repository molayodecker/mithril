defmodule MithrilWeb.Plugs.MobileCall do
  @moduledoc """
  Runs one allowlisted RPC or mobile function whose name is fixed on the route.

  The request path chooses the operation. The body is that operation's arguments.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Mithril.MobileGateway
  alias MithrilWeb.Schemas.MobileCalls

  def init(opts), do: opts

  def open_api_operation(opts), do: MobileCalls.operation(opts)

  def call(conn, {:user_rpc, name}) when is_binary(name) do
    respond(conn, MobileGateway.call_rpc(user_id(conn), name, body_args(conn)))
  end

  def call(conn, {:guest_rpc, name}) when is_binary(name) do
    respond(conn, MobileGateway.call_guest_rpc(name, body_args(conn)))
  end

  def call(conn, {:user_action, name}) when is_binary(name) do
    respond(conn, MobileGateway.invoke_function(user_id(conn), name, body_args(conn)))
  end

  def call(conn, {:guest_action, name}) when is_binary(name) do
    respond(conn, MobileGateway.call_guest_function(name, body_args(conn)))
  end

  defp body_args(conn) do
    case conn.body_params do
      params when is_map(params) -> params
      _other -> %{}
    end
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, {:ok, data}) do
    conn |> json(%{data: data}) |> halt()
  end

  defp respond(conn, {:error, :unknown_function}) do
    conn |> put_status(404) |> json(%{error: "unknown_function"}) |> halt()
  end

  defp respond(conn, {:error, :unknown_table}) do
    conn |> put_status(404) |> json(%{error: "unknown_table"}) |> halt()
  end

  defp respond(conn, {:error, :unknown_embed}) do
    conn |> put_status(400) |> json(%{error: "unknown_embed"}) |> halt()
  end

  defp respond(conn, {:error, :function_not_migrated}) do
    conn
    |> put_status(501)
    |> json(%{
      error: "function_not_migrated",
      message: "This action is not available on Mithril yet."
    })
    |> halt()
  end

  defp respond(conn, {:error, :forbidden}) do
    conn |> put_status(403) |> json(%{error: "forbidden"}) |> halt()
  end

  defp respond(conn, {:error, :bad_request}) do
    conn |> put_status(400) |> json(%{error: "bad_request"}) |> halt()
  end

  defp respond(conn, {:error, {:status, status, body}}) when is_map(body) do
    conn |> put_status(status) |> json(body) |> halt()
  end

  defp respond(conn, {:error, reason}) when is_atom(reason) do
    conn |> put_status(400) |> json(%{error: Atom.to_string(reason)}) |> halt()
  end

  defp respond(conn, {:error, %Postgrex.Error{}}) do
    conn |> put_status(400) |> json(%{error: "database_error"}) |> halt()
  end
end
