defmodule MithrilWeb.DirectAdminContractsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias Mithril.DirectContracts

  alias MithrilWeb.Schemas.DirectAdminContract.{
    AdvanceRequest,
    AdvanceResult,
    AssignmentRequest,
    Created,
    Detail,
    IdResult,
    InvoiceRequest,
    InvoiceResult,
    LetterList,
    LetterRequest,
    LetterResult,
    List,
    PayDueRequest,
    PayDueResult,
    PaydayRequest,
    PaydayResult,
    PublicInvoice,
    PublicLetter,
    WorkerList,
    WriteClient
  }

  alias OpenApiSpex.Schema

  tags(["direct-admin-contracts"])

  operation(:index,
    operation_id: "direct.listAdminContracts",
    summary: "List client contracts for a pay month",
    parameters: [
      month: [in: :query, schema: %Schema{type: :string}, required: false, description: "YYYY-MM"]
    ],
    responses: [ok: {"Contracts", "application/json", List}]
  )

  def index(conn, params) do
    respond(conn, DirectContracts.list(user_id(conn), params["month"]))
  end

  operation(:show,
    operation_id: "direct.showAdminContract",
    summary: "Show one client contract for a pay month",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true],
      month: [in: :query, schema: %Schema{type: :string}, required: false]
    ],
    responses: [ok: {"Contract", "application/json", Detail}]
  )

  def show(conn, %{"id" => id} = params) do
    respond(conn, DirectContracts.show(user_id(conn), id, params["month"]))
  end

  operation(:workers,
    operation_id: "direct.searchAdminContractWorkers",
    summary: "Search workers who can be added to a contract",
    parameters: [
      q: [in: :query, schema: %Schema{type: :string}, required: false]
    ],
    responses: [ok: {"Workers", "application/json", WorkerList}]
  )

  def workers(conn, params) do
    respond(conn, DirectContracts.search_workers(user_id(conn), params["q"]))
  end

  operation(:create,
    operation_id: "direct.createAdminContract",
    summary: "Create a client and contract",
    request_body: {"Contract", "application/json", WriteClient, required: true},
    responses: [ok: {"Created", "application/json", Created}]
  )

  def create(conn, params) do
    respond(conn, DirectContracts.create(user_id(conn), params))
  end

  operation(:update,
    operation_id: "direct.updateAdminContract",
    summary: "Update the client and monthly fee",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Contract", "application/json", WriteClient, required: true},
    responses: [ok: {"Updated", "application/json", IdResult}]
  )

  def update(conn, %{"id" => id} = params) do
    respond(conn, DirectContracts.update_client(user_id(conn), id, params))
  end

  operation(:add_assignment,
    operation_id: "direct.addAdminContractAssignment",
    summary: "Add a worker to a contract",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Assignment", "application/json", AssignmentRequest, required: true},
    responses: [ok: {"Added", "application/json", IdResult}]
  )

  def add_assignment(conn, %{"id" => id} = params) do
    respond(conn, DirectContracts.add_assignment(user_id(conn), id, params))
  end

  operation(:update_assignment,
    operation_id: "direct.updateAdminContractAssignment",
    summary: "Update a worker's pay and weekly advance",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true],
      assignment_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Assignment", "application/json", AssignmentRequest, required: true},
    responses: [ok: {"Updated", "application/json", IdResult}]
  )

  def update_assignment(conn, %{"id" => id, "assignment_id" => assignment_id} = params) do
    respond(conn, DirectContracts.update_assignment(user_id(conn), id, assignment_id, params))
  end

  operation(:end_assignment,
    operation_id: "direct.endAdminContractAssignment",
    summary: "Stop weekly advances for a worker",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true],
      assignment_id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [ok: {"Ended", "application/json", IdResult}]
  )

  def end_assignment(conn, %{"id" => id, "assignment_id" => assignment_id}) do
    respond(conn, DirectContracts.end_assignment(user_id(conn), id, assignment_id))
  end

  operation(:pay_advance,
    operation_id: "direct.payAdminContractAdvance",
    summary: "Credit one weekly advance to a worker wallet",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Advance", "application/json", AdvanceRequest, required: true},
    responses: [ok: {"Paid", "application/json", AdvanceResult}]
  )

  def pay_advance(conn, %{"id" => id} = params) do
    respond(conn, DirectContracts.pay_advance(user_id(conn), id, params))
  end

  operation(:pay_due,
    operation_id: "direct.payAdminContractAdvancesDue",
    summary: "Credit every due weekly advance",
    request_body: {"Pay due", "application/json", PayDueRequest, required: false},
    responses: [ok: {"Paid", "application/json", PayDueResult}]
  )

  def pay_due(conn, params) do
    respond(conn, DirectContracts.pay_due(user_id(conn), params["contractId"], params["month"]))
  end

  operation(:payday,
    operation_id: "direct.runAdminContractPayday",
    summary: "Pay the remainder of the month after advances",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Payday", "application/json", PaydayRequest, required: true},
    responses: [ok: {"Paid", "application/json", PaydayResult}]
  )

  def payday(conn, %{"id" => id} = params) do
    respond(conn, DirectContracts.run_payday(user_id(conn), id, params))
  end

  operation(:send_invoice,
    operation_id: "direct.sendAdminContractInvoice",
    summary: "Save and send the monthly client invoice",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Invoice", "application/json", InvoiceRequest, required: true},
    responses: [ok: {"Sent", "application/json", InvoiceResult}]
  )

  def send_invoice(conn, %{"id" => id} = params) do
    respond(conn, DirectContracts.send_invoice(user_id(conn), id, params))
  end

  operation(:send_letter,
    operation_id: "direct.sendAdminContractLetter",
    summary: "Save and send the client service agreement",
    parameters: [
      id: [in: :path, schema: %Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Letter", "application/json", LetterRequest, required: true},
    responses: [ok: {"Sent", "application/json", LetterResult}]
  )

  def send_letter(conn, %{"id" => id} = params) do
    respond(conn, DirectContracts.send_letter(user_id(conn), id, params))
  end

  operation(:public_show,
    operation_id: "direct.showContractInvoice",
    summary: "Read a contract invoice by its public token",
    parameters: [
      token: [in: :path, schema: %Schema{type: :string}, required: true]
    ],
    responses: [ok: {"Invoice", "application/json", PublicInvoice}]
  )

  def public_show(conn, %{"token" => token}) do
    respond(conn, DirectContracts.public_show(token))
  end

  operation(:my_letters,
    operation_id: "direct.listMyContractLetters",
    summary: "List service agreements sent to the signed-in account",
    tags: ["direct"],
    responses: [ok: {"Letters", "application/json", LetterList}]
  )

  def my_letters(conn, _params) do
    respond(conn, DirectContracts.list_for_customer(user_id(conn)))
  end

  operation(:public_letter,
    operation_id: "direct.showContractLetter",
    summary: "Read a contract letter by its public token",
    parameters: [
      token: [in: :path, schema: %Schema{type: :string}, required: true]
    ],
    responses: [ok: {"Letter", "application/json", PublicLetter}]
  )

  def public_letter(conn, %{"token" => token}) do
    respond(conn, DirectContracts.public_letter(token))
  end

  operation(:public_worker_letter,
    operation_id: "direct.showWorkerContractLetter",
    summary: "Read a worker engagement letter by its public token",
    parameters: [
      token: [in: :path, schema: %Schema{type: :string}, required: true]
    ],
    responses: [ok: {"Letter", "application/json", PublicLetter}]
  )

  def public_worker_letter(conn, %{"token" => token}) do
    respond(conn, DirectContracts.public_worker_letter(token))
  end

  defp user_id(conn), do: conn.assigns.instaclean_user_id

  defp respond(conn, {:ok, payload}) do
    json(conn, payload)
  end

  defp respond(conn, {:error, reason}) do
    {status, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{error: message})
  end

  defp error_response(:forbidden), do: {403, "forbidden"}
  defp error_response(:not_found), do: {404, "not_found"}
  defp error_response(:contract_not_found), do: {404, "contract_not_found"}
  defp error_response(:assignment_not_found), do: {404, "assignment_not_found"}
  defp error_response(:worker_not_found), do: {404, "worker_not_found"}
  defp error_response(:invalid_request), do: {422, "invalid_request"}
  defp error_response(:invalid_amount), do: {422, "invalid_amount"}
  defp error_response(:invalid_email), do: {422, "invalid_email"}
  defp error_response(:invalid_phone), do: {422, "invalid_phone"}
  defp error_response(:missing_email), do: {422, "missing_email"}
  defp error_response(:missing_phone), do: {422, "missing_phone"}
  defp error_response(:advance_not_due), do: {409, "advance_not_due"}
  defp error_response(:advance_already_paid), do: {409, "advance_already_paid"}
  defp error_response(:assignment_ended), do: {409, "assignment_ended"}
  defp error_response(:payday_already_run), do: {409, "payday_already_run"}
  defp error_response(:invoice_already_sent), do: {409, "invoice_already_sent"}
  defp error_response(:letter_needs_worker), do: {422, "letter_needs_worker"}
  defp error_response(:letter_already_sent), do: {409, "letter_already_sent"}
  defp error_response(:client_rates_mismatch), do: {422, "client_rates_mismatch"}
  defp error_response(:worker_already_assigned), do: {409, "worker_already_assigned"}
  defp error_response(:email_not_configured), do: {422, "email_not_configured"}
  defp error_response(:email_delivery_failed), do: {502, "email_delivery_failed"}
  defp error_response(:wallet_not_found), do: {409, "wallet_not_found"}
  defp error_response(:unsupported_currency), do: {422, "unsupported_currency"}
  defp error_response(:amount_too_large), do: {422, "amount_too_large"}
  defp error_response(:database_unavailable), do: {503, "database_unavailable"}
  defp error_response(reason) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp error_response(_), do: {500, "internal_error"}
end
