defmodule MithrilWeb.DirectController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.Direct

  alias MithrilWeb.Schemas.Direct.{
    AdminCandidatesResponse,
    AdminMatchRequest,
    AdminMatchResponse,
    AdminPlacementsResponse,
    CreatePlacementRequest,
    CreatePlacementResponse,
    HelperListResponse,
    HouseholdWorkerResponse,
    PlacementDetailResponse,
    PlacementListResponse,
    PrivateHelperRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct"])

  operation(:list_placements,
    operation_id: "direct.listPlacements",
    summary: "List the signed-in customer's placement requests",
    responses: [ok: {"Placement requests", "application/json", PlacementListResponse}]
  )

  def list_placements(conn, _params) do
    respond(conn, Direct.list_placements(user_id(conn)), fn placements ->
      %{placements: placements}
    end)
  end

  operation(:create_placement,
    operation_id: "direct.createPlacement",
    summary: "Create a household placement request",
    request_body:
      {"Placement request", "application/json", CreatePlacementRequest, required: true},
    responses: [ok: {"Created placement", "application/json", CreatePlacementResponse}]
  )

  def create_placement(conn, params) do
    respond(conn, Direct.create_placement(user_id(conn), params))
  end

  operation(:show_placement,
    operation_id: "direct.showPlacement",
    summary: "Get a placement request and its candidates",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Placement request ID"
      ]
    ],
    responses: [ok: {"Placement detail", "application/json", PlacementDetailResponse}]
  )

  def show_placement(conn, %{"id" => id}) do
    respond(conn, Direct.get_placement(user_id(conn), id))
  end

  operation(:list_helpers,
    operation_id: "direct.listHelpers",
    summary: "List household helpers",
    responses: [ok: {"Household helpers", "application/json", HelperListResponse}]
  )

  def list_helpers(conn, _params) do
    respond(conn, Direct.list_helpers(user_id(conn)), fn helpers -> %{helpers: helpers} end)
  end

  operation(:create_helper,
    operation_id: "direct.createHelper",
    summary: "Add a private household helper",
    request_body: {"Private helper", "application/json", PrivateHelperRequest, required: true},
    responses: [ok: {"Household worker", "application/json", HouseholdWorkerResponse}]
  )

  def create_helper(conn, params) do
    respond(conn, Direct.add_private_helper(user_id(conn), params))
  end

  operation(:hire_match,
    operation_id: "direct.hireMatch",
    summary: "Hire a matched candidate",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Placement match ID"
      ]
    ],
    responses: [ok: {"Household worker", "application/json", HouseholdWorkerResponse}]
  )

  def hire_match(conn, %{"id" => id}) do
    respond(conn, Direct.hire_match(user_id(conn), id))
  end

  operation(:list_admin_placements,
    operation_id: "direct.listAdminPlacements",
    summary: "List placement requests for Direct operations",
    responses: [ok: {"Admin placement requests", "application/json", AdminPlacementsResponse}]
  )

  def list_admin_placements(conn, _params) do
    respond(conn, Direct.list_admin_placements(user_id(conn)), fn placements ->
      %{placements: placements}
    end)
  end

  operation(:list_admin_candidates,
    operation_id: "direct.listAdminCandidates",
    summary: "List vetted placement candidates for Direct operations",
    responses: [ok: {"Admin placement candidates", "application/json", AdminCandidatesResponse}]
  )

  def list_admin_candidates(conn, _params) do
    respond(conn, Direct.list_admin_candidates(user_id(conn)), fn candidates ->
      %{candidates: candidates}
    end)
  end

  operation(:match_admin_candidate,
    operation_id: "direct.matchAdminCandidate",
    summary: "Match a vetted candidate to a placement request",
    parameters: [
      id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Placement request ID"
      ]
    ],
    request_body: {"Candidate match", "application/json", AdminMatchRequest, required: true},
    responses: [ok: {"Placement match", "application/json", AdminMatchResponse}]
  )

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
