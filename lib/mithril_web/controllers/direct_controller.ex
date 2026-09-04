defmodule MithrilWeb.DirectController do
  use Phoenix.Controller, formats: [:json]

  alias Mithril.Direct

  def list_placements(conn, _params) do
    respond(conn, Direct.list_placements(user_id(conn)), fn placements -> %{placements: placements} end)
  end

  def create_placement(conn, params) do
    respond(conn, Direct.create_placement(user_id(conn), params))
  end

  def show_placement(conn, %{"id" => id}) do
    respond(conn, Direct.get_placement(user_id(conn), id))
  end

  def list_helpers(conn, _params) do
    respond(conn, Direct.list_helpers(user_id(conn)), fn helpers -> %{helpers: helpers} end)
  end

  def create_helper(conn, params) do
    respond(conn, Direct.add_private_helper(user_id(conn), params))
  end

  def hire_match(conn, %{"id" => id}) do
    respond(conn, Direct.hire_match(user_id(conn), id))
  end

  def list_admin_placements(conn, _params) do
    respond(conn, Direct.list_admin_placements(user_id(conn)), fn placements -> %{placements: placements} end)
  end

  def list_admin_candidates(conn, _params) do
    respond(conn, Direct.list_admin_candidates(user_id(conn)), fn candidates -> %{candidates: candidates} end)
  end

  def match_admin_candidate(conn, %{"id" => id} = params) do
    respond(conn, Direct.match_admin_candidate(user_id(conn), id, params))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, result, mapper \\ & &1)

  defp respond(conn, {:ok, value}, mapper) do
    json(conn, mapper.(value))
  end

  defp respond(conn, {:error, reason}, _mapper) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:invalid_user), do: {401, "invalid_user"}
  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:placement_closed), do: {409, "placement_closed"}
  defp error_response(:candidate_unavailable), do: {409, "candidate_unavailable"}
  defp error_response(:candidate_missing_phone), do: {409, "candidate_missing_phone"}
  defp error_response(:consent_required), do: {409, "consent_required"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
