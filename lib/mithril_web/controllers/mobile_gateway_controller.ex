defmodule MithrilWeb.MobileGatewayController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.MobileGateway
  alias OpenApiSpex.Schema

  tags(["mobile"])

  operation(:rpc,
    operation_id: "mobile.rpc",
    summary: "Call an allowlisted database function as the signed-in user",
    parameters: [
      name: [in: :path, schema: %Schema{type: :string}, required: true]
    ],
    responses: [
      ok: {"Function result", "application/json", %Schema{type: :object}}
    ]
  )

  def rpc(conn, %{"name" => name} = params) do
    respond(conn, MobileGateway.call_rpc(user_id(conn), name, params["args"]))
  end

  operation(:query,
    operation_id: "mobile.query",
    summary: "Run an allowlisted table query as the signed-in user",
    responses: [
      ok: {"Query result", "application/json", %Schema{type: :object}}
    ]
  )

  def query(conn, params) do
    respond(conn, MobileGateway.run_query(user_id(conn), params))
  end

  operation(:function,
    operation_id: "mobile.function",
    summary: "Invoke a mobile edge-function replacement",
    parameters: [
      name: [in: :path, schema: %Schema{type: :string}, required: true]
    ],
    responses: [
      ok: {"Function result", "application/json", %Schema{type: :object}}
    ]
  )

  def function(conn, params) do
    name = function_name(params["name"])
    body = Map.drop(params, ["name"])
    respond(conn, MobileGateway.invoke_function(user_id(conn), name, body))
  end

  defp function_name(name) when is_list(name), do: Enum.join(name, "/")
  defp function_name(name), do: name

  defp respond(conn, {:ok, data}) do
    json(conn, %{data: data})
  end

  defp respond(conn, {:error, :unknown_function}) do
    conn |> put_status(404) |> json(%{error: "unknown_function"})
  end

  defp respond(conn, {:error, :unknown_table}) do
    conn |> put_status(404) |> json(%{error: "unknown_table"})
  end

  defp respond(conn, {:error, :unknown_embed}) do
    conn |> put_status(400) |> json(%{error: "unknown_embed"})
  end

  defp respond(conn, {:error, :function_not_migrated}) do
    conn
    |> put_status(501)
    |> json(%{
      error: "function_not_migrated",
      message: "This action is not available on Mithril yet."
    })
  end

  defp respond(conn, {:error, :forbidden}) do
    conn |> put_status(403) |> json(%{error: "forbidden"})
  end

  defp respond(conn, {:error, :bad_request}) do
    conn |> put_status(400) |> json(%{error: "bad_request"})
  end

  defp respond(conn, {:error, {:status, status, body}}) when is_map(body) do
    conn |> put_status(status) |> json(body)
  end

  defp respond(conn, {:error, reason}) when is_atom(reason) do
    conn |> put_status(400) |> json(%{error: Atom.to_string(reason)})
  end

  defp respond(conn, {:error, %Postgrex.Error{}}) do
    conn |> put_status(400) |> json(%{error: "database_error"})
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id
end
