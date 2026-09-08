defmodule MithrilWeb.DirectVideoController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectVideos

  alias MithrilWeb.Schemas.DirectVideo.{
    CandidateVideoResponse,
    UpdateCandidateVideoRequest
  }

  alias OpenApiSpex.Schema

  tags(["direct"])

  operation(:show_candidate_video,
    operation_id: "direct.showCandidateVideo",
    summary: "Get a shortlisted candidate's video introduction",
    parameters: [
      placement_id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Placement request ID"
      ],
      candidate_id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Candidate user ID"
      ]
    ],
    responses: [ok: {"Candidate video", "application/json", CandidateVideoResponse}]
  )

  def show_candidate_video(conn, %{"placement_id" => placement_id, "candidate_id" => candidate_id}) do
    respond(
      conn,
      DirectVideos.show_candidate_video(user_id(conn), placement_id, candidate_id)
    )
  end

  operation(:show_admin_candidate_video,
    operation_id: "direct.showAdminCandidateVideo",
    summary: "Get video introduction metadata for a vetted Direct candidate",
    parameters: [
      candidate_id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Candidate user ID"
      ]
    ],
    responses: [ok: {"Candidate video", "application/json", CandidateVideoResponse}]
  )

  def show_admin_candidate_video(conn, %{"candidate_id" => candidate_id}) do
    respond(conn, DirectVideos.show_admin_candidate_video(user_id(conn), candidate_id))
  end

  operation(:update_admin_candidate_video,
    operation_id: "direct.updateAdminCandidateVideo",
    summary: "Attach or clear a vetted candidate's video introduction",
    parameters: [
      candidate_id: [
        in: :path,
        schema: %Schema{type: :string, format: :uuid},
        required: true,
        description: "Candidate user ID"
      ]
    ],
    request_body:
      {"Candidate video metadata", "application/json", UpdateCandidateVideoRequest, required: true},
    responses: [ok: {"Candidate video", "application/json", CandidateVideoResponse}]
  )

  def update_admin_candidate_video(conn, %{"candidate_id" => candidate_id} = params) do
    respond(conn, DirectVideos.update_admin_candidate_video(user_id(conn), candidate_id, params))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, {:ok, value}), do: json(conn, value)

  defp respond(conn, {:error, reason}) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:candidate_unavailable), do: {409, "candidate_unavailable"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_reason), do: {500, "internal_error"}
end
