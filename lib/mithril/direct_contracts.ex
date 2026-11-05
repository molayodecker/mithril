defmodule Mithril.DirectContracts do
  @moduledoc """
  Client contracts for ongoing work.

  A weekly advance credits the worker's Instaclean wallet and is deducted from
  that month's pay. It does not change the Finance loan balance or the client fee.
  """

  require Logger

  alias Mithril.Auth
  alias Mithril.DirectAdminActor
  alias Mithril.DirectAdminInvoices
  alias Mithril.DirectContracts.Calendar
  alias Mithril.WhatsApp.ContractLetterTemplate
  alias Mithril.WhatsApp.WorkerAddedTemplate
  alias Mithril.WhatsApp.InvoiceTemplate
  alias Mithril.DirectContracts.Letter
  alias Mithril.Repo

  def list(user_id, month_param) do
    with :ok <- require_admin(user_id),
         {:ok, month} <- month_or_current(month_param) do
      case contract_rows(nil) do
        {:ok, contracts} -> {:ok, present_list(contracts, month)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def show(user_id, contract_id, month_param) do
    with :ok <- require_admin(user_id),
         {:ok, month} <- month_or_current(month_param),
         {:ok, id} <- cast_uuid(contract_id) do
      case contract_rows(id) do
        {:ok, [contract]} -> {:ok, present_detail(contract, month)}
        {:ok, []} -> {:error, :contract_not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def search_workers(user_id, query) do
    with :ok <- require_admin(user_id),
         {:ok, term} <- search_term(query) do
      if term == "" do
        {:ok, %{"workers" => []}}
      else
        search_worker_rows(term)
      end
    end
  end

  defp search_worker_rows(term) do
    case Repo.query(
           """
           SELECT u.id::text,
                  COALESCE(NULLIF(btrim(p.fullname), ''), NULLIF(btrim(u.email), ''), 'Worker'),
                  u.phone,
                  w.balance_subunit
           FROM public.cleaner_data cd
           JOIN public.users u ON u.id = cd.user_id
           LEFT JOIN public.profiles p ON p.id = u.id
           LEFT JOIN public.wallets w ON w.user_id = u.id
           WHERE COALESCE(p.fullname, '') ILIKE $1
              OR COALESCE(u.phone, '') ILIKE $1
              OR COALESCE(u.email, '') ILIKE $1
           ORDER BY 2
           LIMIT 20
           """,
           [like_pattern(term)]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         %{
           "workers" =>
             Enum.map(rows, fn [id, name, phone, balance] ->
               %{
                 "userId" => id,
                 "name" => name,
                 "phone" => phone,
                 "walletBalanceMinor" => balance
               }
             end)
         }}

      {:error, error} ->
        map_pg(error)
    end
  end

  def create(user_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, client} <- client_attrs(params),
         {:ok, fee} <- positive_int(param(params, "monthlyFeeMinor")),
         {:ok, placement_id} <- optional_uuid(param(params, "placementId")),
         {:ok, start_on} <- optional_date(param(params, "startOn")),
         {:ok, include_invoices} <- optional_boolean(param(params, "includeInvoices")) do
      case Repo.transaction(fn ->
             %{rows: [[client_uid]]} =
               fetch!(
                 """
                 INSERT INTO public.direct_contract_clients (name, kind, billing_contact, phone, email)
                 VALUES ($1, $2, $3, $4, $5)
                 RETURNING id
                 """,
                 [
                   client.name,
                   client.kind,
                   client.billing_contact,
                   client.phone,
                   client.email
                 ]
               )

             %{rows: [[contract_uid]]} =
               fetch!(
                 """
                 INSERT INTO public.direct_contracts (
                   client_id, monthly_fee_minor, placement_id, start_on, include_invoices
                 )
                 VALUES ($1, $2, $3, $4, COALESCE($5::boolean, true))
                 RETURNING id
                 """,
                 [
                   client_uid,
                   fee,
                   placement_id && elem(Ecto.UUID.dump(placement_id), 1),
                   start_on,
                   include_invoices
                 ]
               )

             %{"id" => uuid_text(contract_uid), "clientId" => uuid_text(client_uid)}
           end) do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> unwrap(reason)
      end
    end
  end

  def update_client(user_id, contract_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, client} <- client_attrs(params),
         {:ok, fee} <- positive_int(param(params, "monthlyFeeMinor")),
         {:ok, start_on} <- optional_date(param(params, "startOn")),
         {:ok, include_invoices} <- optional_boolean(param(params, "includeInvoices")) do
      case Repo.transaction(fn ->
             result =
               fetch!(
                 """
                 UPDATE public.direct_contract_clients cl
                 SET name = $2, kind = $3, billing_contact = $4, phone = $5, email = $6, updated_at = now()
                 FROM public.direct_contracts c
                 WHERE c.id = $1 AND cl.id = c.client_id
                 RETURNING c.id::text
                 """,
                 [
                   contract_uid,
                   client.name,
                   client.kind,
                   client.billing_contact,
                   client.phone,
                   client.email
                 ]
               )

             case result.rows do
               [[id]] ->
                 fetch!(
                   """
                   UPDATE public.direct_contracts
                   SET monthly_fee_minor = $2,
                       start_on = COALESCE($3::date, start_on),
                       include_invoices = COALESCE($4::boolean, include_invoices),
                       updated_at = now()
                   WHERE id = $1
                   """,
                   [contract_uid, fee, start_on, include_invoices]
                 )

                 %{"id" => id}

               [] ->
                 Repo.rollback(:contract_not_found)
             end
           end) do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> unwrap(reason)
      end
    end
  end

  def add_assignment(user_id, contract_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, attrs} <- assignment_attrs(params) do
      case transact(fn -> insert_assignment(contract_uid, attrs) end) do
        {:ok, %{assignment: assignment, notice: notice}} ->
          {:ok, assignment_with_notice(assignment, notify_added_worker(user_id, notice))}

        other ->
          other
      end
    end
  end

  def update_assignment(user_id, contract_id, assignment_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, assignment_uid} <- dump_uuid(assignment_id),
         {:ok, attrs} <- assignment_update_attrs(params) do
      transact(fn ->
        result =
          fetch!(
            """
            UPDATE public.direct_contract_assignments
            SET role_label = $3,
                monthly_pay_minor = $4,
                client_rate_minor = $5,
                weekly_advance_minor = $6,
                advance_weekday = $7,
                advance_mode = $8,
                updated_at = now()
            WHERE id = $2 AND contract_id = $1 AND status = 'active'
            RETURNING id::text
            """,
            [
              contract_uid,
              assignment_uid,
              attrs.role,
              attrs.pay,
              attrs.rate,
              attrs.amount,
              attrs.weekday,
              attrs.mode
            ]
          )

        case result.rows do
          [[id]] -> %{"id" => id}
          [] -> Repo.rollback(:assignment_not_found)
        end
      end)
    end
  end

  def end_assignment(user_id, contract_id, assignment_id) do
    with :ok <- require_admin(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, assignment_uid} <- dump_uuid(assignment_id) do
      today = Calendar.today()

      transact(fn ->
        result =
          fetch!(
            """
            UPDATE public.direct_contract_assignments
            SET status = 'ended', ended_on = $3, advance_mode = 'manual', updated_at = now()
            WHERE id = $2 AND contract_id = $1 AND status = 'active'
            RETURNING id::text, ended_on
            """,
            [contract_uid, assignment_uid, today]
          )

        case result.rows do
          [[id, ended_on]] -> %{"id" => id, "endedOn" => Date.to_iso8601(ended_on)}
          [] -> Repo.rollback(:assignment_not_found)
        end
      end)
    end
  end

  def remove_assignment(user_id, contract_id, assignment_id) do
    with :ok <- require_admin(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, assignment_uid} <- dump_uuid(assignment_id) do
      transact(fn ->
        case fetch!(
               """
               SELECT id
               FROM public.direct_contract_assignments
               WHERE id = $2 AND contract_id = $1
               FOR UPDATE
               """,
               [contract_uid, assignment_uid]
             ).rows do
          [] -> Repo.rollback(:assignment_not_found)
          [_] -> :ok
        end

        if assignment_count(
             "SELECT COUNT(*) FROM public.direct_contract_advances WHERE assignment_id = $1",
             [assignment_uid]
           ) > 0 or
             assignment_count(
               "SELECT COUNT(*) FROM public.direct_contract_payday_lines WHERE assignment_id = $1",
               [assignment_uid]
             ) > 0 do
          Repo.rollback(:assignment_has_payments)
        end

        if relation?("public.direct_contract_worker_letters") and
             assignment_count(
               "SELECT COUNT(*) FROM public.direct_contract_worker_letters WHERE assignment_id = $1",
               [assignment_uid]
             ) > 0 do
          Repo.rollback(:assignment_has_letter)
        end

        # Even an unsent invoice may already have a persisted per-worker line.
        # Preserve the invoice audit trail and report a useful conflict rather
        # than allowing a foreign-key failure to surface as a database outage.
        if relation?("public.direct_contract_invoice_lines") and
             assignment_count(
               "SELECT COUNT(*) FROM public.direct_contract_invoice_lines WHERE assignment_id = $1",
               [assignment_uid]
             ) > 0 do
          Repo.rollback(:assignment_has_invoice)
        end

        %{rows: [[id]]} =
          fetch!(
            """
            DELETE FROM public.direct_contract_assignments
            WHERE id = $2 AND contract_id = $1
            RETURNING id::text
            """,
            [contract_uid, assignment_uid]
          )

        %{"id" => id}
      end)
    end
  end

  def pay_advance(user_id, contract_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, assignment_uid} <- dump_uuid(param(params, "assignmentId")),
         {:ok, week} <- Calendar.parse_date(param(params, "weekOn")) do
      with_admin(admin_uid, fn ->
        pay_locked(admin_uid, contract_uid, assignment_uid, week, :manual)
      end)
    end
  end

  def pay_due(user_id, contract_id, month_param) do
    with :ok <- require_admin(user_id),
         {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, month} <- month_or_current(month_param),
         {:ok, contract_filter} <- optional_uuid_dump(contract_id) do
      case due_weeks(contract_filter, month) do
        {:ok, weeks} -> pay_each(admin_uid, weeks)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def run_payday(user_id, contract_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, month} <- month_or_current(param(params, "month")) do
      with_admin(admin_uid, fn ->
        close_payday(admin_uid, contract_uid, month)
      end)
    end
  end

  def remove_invoice(user_id, contract_id, invoice_id) do
    with :ok <- require_admin(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, invoice_uid} <- dump_uuid(invoice_id) do
      transact(fn ->
        case fetch!(
               """
               DELETE FROM public.direct_contract_invoices
               WHERE id = $2 AND contract_id = $1 AND sending_at IS NULL
               RETURNING id::text
               """,
               [contract_uid, invoice_uid]
             ).rows do
          [[id]] ->
            %{"id" => id}

          [] ->
            case fetch!(
                   "SELECT sending_at IS NOT NULL FROM public.direct_contract_invoices WHERE id = $1 AND contract_id = $2",
                   [invoice_uid, contract_uid]
                 ).rows do
              [[true]] -> Repo.rollback(:invoice_delivery_in_progress)
              _ -> Repo.rollback(:contract_invoice_not_found)
            end
        end
      end)
    end
  end

  def send_invoice(user_id, contract_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, month} <- month_or_current(param(params, "month")),
         {:ok, style} <- one_of(param(params, "style"), ~w(one_line per_worker)),
         {:ok, channel} <- one_of(param(params, "channel"), ~w(email whatsapp)) do
      with {:ok, invoice} <- ensure_invoice(admin_uid, contract_uid, month, style),
           :ok <- claim_invoice_delivery(invoice["id"]),
           :ok <- deliver_claimed_invoice(admin_uid, invoice, channel),
           {:ok, sent} <- mark_sent(invoice["id"], channel) do
        {:ok, sent}
      end
    end
  end

  def public_show(token) when is_binary(token) do
    if token =~ ~r/\A[0-9a-f]{64}\z/ do
      case Repo.query(
             """
             SELECT i.invoice_no, i.issued_on, i.due_on, i.total_minor, i.currency,
                    cl.name, cl.billing_contact, cl.phone, cl.email, i.period_month
             FROM public.direct_contract_invoices i
             JOIN public.direct_contracts c ON c.id = i.contract_id
             JOIN public.direct_contract_clients cl ON cl.id = c.client_id
             WHERE i.public_token = $1
             """,
             [token]
           ) do
        {:ok, %{rows: [row]}} -> {:ok, public_invoice(token, row)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, error} -> map_pg(error)
      end
    else
      {:error, :not_found}
    end
  end

  def public_show(_), do: {:error, :not_found}

  def save_letter(user_id, contract_id) do
    with :ok <- require_admin(user_id),
         {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, letter} <- prepare_letter(admin_uid, contract_uid, false) do
      {:ok, letter_result(letter, nil, false)}
    end
  end

  def send_letter(user_id, contract_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, admin_uid} <- dump_uuid(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, channel} <- one_of(param(params, "channel"), ~w(email whatsapp)) do
      with {:ok, letter} <- prepare_letter(admin_uid, contract_uid, true) do
        case deliver_letter(admin_uid, letter, channel) do
          :ok ->
            mark_letter_sent(letter["id"], channel, letter["publicToken"])

          {:error, reason} ->
            release_letter_claim(letter["id"])
            {:error, reason}
        end
      end
    end
  end

  def list_for_customer(user_id) do
    with {:ok, uid} <- dump_uuid(user_id) do
      # Contact fields are editable and unverified. Only letters explicitly tied
      # to this user (worker assignments) can be returned here.
      worker_letters_for_account(uid)
    else
      :error -> {:error, :not_found}
    end
  end

  def sign_provider(user_id, contract_id, params) when is_map(params) do
    with :ok <- require_admin(user_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, attrs} <- signature_attrs(params) do
      case transact(fn -> stamp_provider_signature(contract_uid, attrs) end) do
        {:ok, _} -> {:ok, %{"id" => contract_id}}
        {:error, reason} -> unwrap(reason)
      end
    end
  end

  def sign_public_letter(token, params) when is_map(params) do
    sign_public(token, params, :client)
  end

  def sign_public_worker_letter(token, params) when is_map(params) do
    sign_public(token, params, :worker)
  end

  def public_letter(token) when is_binary(token) do
    if token =~ ~r/\A[0-9a-f]{64}\z/ do
      case Repo.query(
             """
             SELECT l.letter_no, l.issued_on, l.start_on, l.monthly_fee_minor, l.currency, l.client_name,
                    l.billing_contact, l.phone, l.email, l.preamble, l.workers, l.clauses,
                    (c.status = 'active' AND EXISTS (
                      SELECT 1 FROM public.direct_contract_assignments a
                      WHERE a.contract_id = c.id AND a.status = 'active'
                    )),
                    l.provider_signer_name, l.provider_signed_at, l.provider_signature,
                    l.client_signer_name, l.client_signed_at, l.client_signature
             FROM public.direct_contract_letters l
             JOIN public.direct_contracts c ON c.id = l.contract_id
             WHERE l.public_token = $1
             """,
             [token]
           ) do
        {:ok, %{rows: [row]}} -> {:ok, public_letter_payload(row)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, error} -> map_pg(error)
      end
    else
      {:error, :not_found}
    end
  end

  def public_letter(_), do: {:error, :not_found}

  def public_worker_letter(token) when is_binary(token) do
    if token =~ ~r/\A[0-9a-f]{64}\z/ do
      case Repo.query(
             """
             SELECT l.letter_no, l.issued_on, l.start_on, l.monthly_pay_minor, l.weekly_advance_minor, l.currency,
                    l.worker_name, l.role_label, l.client_name, l.phone, l.email, l.preamble, l.clauses,
                    (c.status = 'active' AND a.status = 'active'),
                    l.provider_signer_name, l.provider_signed_at, l.provider_signature,
                    l.worker_signer_name, l.worker_signed_at, l.worker_signature
             FROM public.direct_contract_worker_letters l
             JOIN public.direct_contract_assignments a ON a.id = l.assignment_id
             JOIN public.direct_contracts c ON c.id = l.contract_id
             WHERE l.public_token = $1
             """,
             [token]
           ) do
        {:ok, %{rows: [row]}} -> {:ok, worker_letter_payload(row)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, error} -> map_pg(error)
      end
    else
      {:error, :not_found}
    end
  end

  def public_worker_letter(_), do: {:error, :not_found}

  defp sign_public(token, params, role) when is_binary(token) do
    with {:ok, attrs} <- signature_attrs(params),
         true <- token =~ ~r/\A[0-9a-f]{64}\z/ do
      case transact(fn -> stamp_counterparty_signature(token, attrs, role) end) do
        {:ok, payload} -> {:ok, payload}
        {:error, reason} -> unwrap(reason)
      end
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  defp sign_public(_, _, _), do: {:error, :not_found}

  defp stamp_provider_signature(contract_uid, attrs) do
    case fetch!(
           """
           UPDATE public.direct_contracts
           SET provider_signer_name = $2, provider_signed_at = now(), provider_signature = $3, updated_at = now()
           WHERE id = $1 AND provider_signed_at IS NULL
           RETURNING provider_signer_name, provider_signed_at, provider_signature
           """,
           [contract_uid, attrs.name, attrs.image]
         ).rows do
      [[name, signed_at, image]] ->
        copy_provider_signature(
          "public.direct_contract_letters",
          contract_uid,
          name,
          signed_at,
          image
        )

        copy_provider_signature(
          "public.direct_contract_worker_letters",
          contract_uid,
          name,
          signed_at,
          image
        )

        :ok

      [] ->
        case fetch!("SELECT provider_signed_at FROM public.direct_contracts WHERE id = $1", [
               contract_uid
             ]).rows do
          [] -> Repo.rollback(:contract_not_found)
          [[nil]] -> Repo.rollback(:invalid_request)
          _ -> Repo.rollback(:letter_already_signed)
        end
    end
  end

  defp copy_provider_signature(table, contract_uid, name, signed_at, image) do
    fetch!(
      """
      UPDATE #{table}
      SET provider_signer_name = $2, provider_signed_at = $3, provider_signature = $4
      WHERE contract_id = $1 AND provider_signed_at IS NULL
      """,
      [contract_uid, name, signed_at, image]
    )
  end

  defp stamp_counterparty_signature(token, attrs, :client) do
    stamp_role_signature(
      "public.direct_contract_letters",
      "client_signer_name",
      "client_signed_at",
      "client_signature",
      token,
      attrs,
      &public_letter/1
    )
  end

  defp stamp_counterparty_signature(token, attrs, :worker) do
    stamp_role_signature(
      "public.direct_contract_worker_letters",
      "worker_signer_name",
      "worker_signed_at",
      "worker_signature",
      token,
      attrs,
      &public_worker_letter/1
    )
  end

  defp stamp_role_signature(table, name_column, at_column, image_column, token, attrs, reader) do
    # Hold the contract and assignment locks until the signature transaction commits.
    # This serializes signing with assignment termination and contract closure.
    lock_signable_letter!(table, token)

    case reader.(token) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, %{"active" => false}} ->
        Repo.rollback(:letter_not_active)

      {:ok, %{"counterpartySignature" => signature}} when not is_nil(signature) ->
        Repo.rollback(:letter_already_signed)

      {:ok, _} ->
        %{num_rows: rows} =
          fetch!(
            """
            UPDATE #{table}
            SET #{name_column} = $2, #{at_column} = now(), #{image_column} = $3
            WHERE public_token = $1 AND #{at_column} IS NULL
            """,
            [token, attrs.name, attrs.image]
          )

        case rows do
          1 ->
            case reader.(token) do
              {:ok, payload} -> payload
              {:error, reason} -> Repo.rollback(reason)
            end

          _ ->
            Repo.rollback(:letter_already_signed)
        end
    end
  end

  defp lock_signable_letter!(table, token) do
    case fetch!(
           "SELECT contract_id, sent_at FROM #{table} WHERE public_token = $1",
           [token]
         ).rows do
      [] ->
        Repo.rollback(:not_found)

      [[contract_uid, sent_at]] ->
        case fetch!(
               "SELECT status FROM public.direct_contracts WHERE id = $1 FOR UPDATE",
               [contract_uid]
             ).rows do
          [["active"]] -> :ok
          _ -> Repo.rollback(:letter_not_active)
        end

        # Lock all assignments for the client letter, or the particular worker
        # assignment for the worker letter. end_assignment updates these rows.
        assignment_filter =
          if table == "public.direct_contract_worker_letters" do
            "a.contract_id = $1 AND a.id = (SELECT assignment_id FROM #{table} WHERE public_token = $2)"
          else
            "a.contract_id = $1"
          end

        params =
          if table == "public.direct_contract_worker_letters",
            do: [contract_uid, token],
            else: [contract_uid]

        fetch!(
          """
          SELECT a.id
          FROM public.direct_contract_assignments a
          WHERE #{assignment_filter}
          ORDER BY a.id
          FOR UPDATE
          """,
          params
        )

        # Unsent documents can be regenerated with different terms on retry.
        # Sign only successfully delivered, immutable letters.
        if is_nil(sent_at), do: Repo.rollback(:letter_not_sent)
    end
  end

  defp current_provider_signature(contract_uid) do
    case fetch!(
           """
           SELECT provider_signer_name, provider_signed_at, provider_signature
           FROM public.direct_contracts
           WHERE id = $1
           """,
           [contract_uid]
         ).rows do
      [[name, signed_at, image]] -> [name, signed_at, image]
      _ -> [nil, nil, nil]
    end
  end

  defp letter_preview(contract) do
    contract
    |> Letter.preview(active_letter_workers(contract.id))
    |> Map.put(
      "providerSignature",
      signature_map(
        contract.provider_signer_name,
        contract.provider_signed_at,
        contract.provider_signature
      )
    )
    |> then(fn preview ->
      Map.put(preview, "counterpartySignature", latest_client_signature(contract.id, preview))
    end)
  end

  defp latest_client_signature(contract_id, preview) do
    with {:ok, uid} <- dump_uuid(contract_id),
         {:ok, %{rows: [[name, signed_at, image, start_on, fee, currency,
                         client_name, billing_contact, phone, email, preamble,
                         workers, clauses]]}} <-
           Repo.query(
             """
             SELECT client_signer_name, client_signed_at, client_signature,
                    start_on, monthly_fee_minor, currency, client_name,
                    billing_contact, phone, email, preamble, workers, clauses
             FROM public.direct_contract_letters
             WHERE contract_id = $1
             ORDER BY created_at DESC, id DESC
             LIMIT 1
             """,
             [uid]
           ),
         true <- not is_nil(signed_at),
         true <-
           signed_letter_matches_preview?(preview, %{
             "startOn" => Date.to_iso8601(start_on),
             "monthlyFeeMinor" => fee,
             "currency" => currency,
             "clientName" => client_name,
             "billingContact" => billing_contact,
             "phone" => phone,
             "email" => email,
             "preamble" => preamble,
             "workers" => workers,
             "clauses" => clauses
           }) do
      signature_map(name, signed_at, image)
    else
      _ -> nil
    end
  end

  defp signed_letter_matches_preview?(preview, snapshot) do
    Enum.all?(snapshot, fn {key, value} -> Map.get(preview, key) == value end)
  end

  defp signature_attrs(params) do
    name = params |> param("signerName") |> signature_name()
    image = param(params, "signature")

    cond do
      name == :error -> {:error, :invalid_request}
      not valid_signature?(image) -> {:error, :invalid_request}
      true -> {:ok, %{name: name, image: image}}
    end
  end

  defp signature_name(value) when is_binary(value) do
    name = String.trim(value)
    if name != "" and String.length(name) <= 120, do: name, else: :error
  end

  defp signature_name(_), do: :error

  defp valid_signature?(value) when is_binary(value) do
    byte_size(value) in 50..80_000 and
      Regex.match?(~r{\Adata:image/png;base64,[A-Za-z0-9+/=]+\z}, value)
  end

  defp valid_signature?(_), do: false

  defp signature_map(nil, _, _), do: nil
  defp signature_map(_, nil, _), do: nil
  defp signature_map(_, _, nil), do: nil

  defp signature_map(name, signed_at, image) do
    %{
      "signerName" => name,
      "signedAt" => signature_timestamp(signed_at),
      "signature" => image
    }
  end

  defp signature_timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp signature_timestamp(%NaiveDateTime{} = value) do
    value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  def pay_automatic_advances do
    today = Calendar.today()
    month = Calendar.period_start(today)

    case due_weeks(nil, month, today, :automatic) do
      {:ok, weeks} ->
        Enum.reduce(weeks, :ok, fn week, acc ->
          case automatic_one(week) do
            {:ok, _} ->
              acc

            {:error, reason} ->
              Logger.error("contract advance automatic failed: #{inspect(reason)}")
              {:error, reason}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp present_list(contracts, month) do
    ids = Enum.map(contracts, & &1.id)
    assignments = assignments_for(ids, month)
    advances = advances_for(ids, month)
    invoices = invoices_for(ids, month)
    closed = closed_contracts(ids, month)
    today = Calendar.today()

    rows =
      Enum.map(contracts, fn contract ->
        workers = Map.get(assignments, contract.id, [])
        paid = Map.get(advances, contract.id, [])

        present_summary(
          contract,
          workers,
          paid,
          Map.get(invoices, contract.id),
          month,
          today,
          MapSet.member?(closed, contract.id)
        )
      end)

    due =
      Enum.reduce(rows, 0, fn row, count ->
        count + row["dueAdvanceCount"]
      end)

    %{
      "month" => Calendar.month_key(month),
      "periodLabel" => Calendar.month_label(month),
      "today" => Date.to_iso8601(today),
      "payday" => Date.to_iso8601(Calendar.last_working_day(month)),
      "paydayLabel" => Calendar.short_date(Calendar.last_working_day(month)),
      "dueAdvanceCount" => due,
      "contracts" => rows
    }
  end

  defp present_detail(contract, month) do
    assignments = assignments_for([contract.id], month)
    advances = advances_for([contract.id], month)
    invoices = invoices_for([contract.id], month)
    closed = MapSet.member?(closed_contracts([contract.id], month), contract.id)
    today = Calendar.today()
    workers = Map.get(assignments, contract.id, [])
    paid = Map.get(advances, contract.id, [])

    summary =
      present_summary(
        contract,
        workers,
        paid,
        Map.get(invoices, contract.id),
        month,
        today,
        closed
      )

    history = invoice_history(contract, today)

    summary
    |> Map.put("month", Calendar.month_key(month))
    |> Map.put("periodLabel", Calendar.month_label(month))
    |> Map.put("payday", Date.to_iso8601(Calendar.last_working_day(month)))
    |> Map.put("paydayLabel", Calendar.short_date(Calendar.last_working_day(month)))
    |> Map.put("today", Date.to_iso8601(today))
    |> Map.put("client", client_map(contract))
    |> Map.put("placementId", contract.placement_id)
    |> Map.put("invoices", history)
    |> Map.put("advances", present_advance_rows(paid))
    |> Map.put("paydayClosed", closed)
    |> Map.put("letterPreview", letter_preview(contract))
    |> Map.put("letters", letter_history(contract.id))
    |> Map.put("workerLetters", worker_letter_history(contract.id))
  end

  defp present_summary(contract, workers, advances, invoice, month, today, closed) do
    presented = Enum.map(workers, &present_assignment(&1, advances, month, today))
    gross = Enum.reduce(presented, 0, &(&1["monthlyPayMinor"] + &2))
    advance_total = Enum.reduce(presented, 0, &(&1["advancesPaidMinor"] + &2))
    net = if closed, do: 0, else: Enum.reduce(presented, 0, &(&1["netMinor"] + &2))
    due = if closed, do: 0, else: Enum.reduce(presented, 0, &(&1["dueCount"] + &2))

    %{
      "id" => contract.id,
      "status" => contract.status,
      "clientName" => contract.name,
      "clientKind" => contract.kind,
      "billingContact" => contract.billing_contact,
      "phone" => contract.phone,
      "email" => contract.email,
      "monthlyFeeMinor" => contract.monthly_fee_minor,
      "currency" => contract.currency,
      "workerPayMinor" => gross,
      "marginMinor" => contract.monthly_fee_minor - gross,
      "advancesPaidMinor" => advance_total,
      "netDueMinor" => net,
      "dueAdvanceCount" => due,
      "paydayClosed" => closed,
      "workers" => presented,
      "invoiceStatus" => invoice_status(invoice, month, today),
      "invoiceNo" => invoice && invoice.invoice_no
    }
  end

  defp present_assignment(assignment, advances, month, today) do
    own =
      Enum.filter(advances, &(&1.assignment_id == assignment.id and in_month?(&1.week_on, month)))

    paid_dates = Map.new(own, &{&1.week_on, &1})

    weeks =
      if assignment.weekly_advance_minor do
        month
        |> Calendar.weekday_dates(assignment.advance_weekday)
        |> Enum.filter(&week_visible?(&1, assignment))
        |> Enum.map(fn date ->
          record = Map.get(paid_dates, date)
          status = Calendar.week_status(date, today, record != nil)

          %{
            "date" => Date.to_iso8601(date),
            "label" => Calendar.short_date(date),
            "status" => status,
            "reference" => record && record.reference
          }
        end)
      else
        []
      end

    advances_paid = Enum.reduce(own, 0, &(&1.amount_minor + &2))

    due_dates =
      for week <- weeks,
          week["status"] == "due" and assignment.status == "active",
          do: week["date"]

    %{
      "id" => assignment.id,
      "workerId" => assignment.worker_id,
      "workerName" => assignment.worker_name,
      "phone" => assignment.phone,
      "walletBalanceMinor" => assignment.wallet_balance_minor,
      "status" => assignment.status,
      "roleLabel" => assignment.role_label,
      "monthlyPayMinor" => assignment.monthly_pay_minor,
      "clientRateMinor" => assignment.client_rate_minor,
      "weeklyAdvanceMinor" => assignment.weekly_advance_minor,
      "advanceWeekday" => assignment.advance_weekday,
      "advanceWeekdayLabel" =>
        assignment.advance_weekday && Calendar.weekday_name(assignment.advance_weekday),
      "advanceMode" => assignment.advance_mode,
      "weeks" => weeks,
      "advancesPaidMinor" => advances_paid,
      "advancesPaidCount" => length(own),
      "netMinor" => Calendar.net_minor(assignment.monthly_pay_minor, advances_paid),
      "dueCount" => length(due_dates),
      "nextDueOn" => List.first(due_dates)
    }
  end

  defp present_advance_rows(advances) do
    advances
    |> Enum.sort_by(& &1.week_on, {:desc, Date})
    |> Enum.map(fn advance ->
      %{
        "id" => advance.id,
        "weekOn" => Date.to_iso8601(advance.week_on),
        "weekLabel" => Calendar.short_date(advance.week_on),
        "workerName" => advance.worker_name,
        "amountMinor" => advance.amount_minor,
        "paidVia" => advance.paid_via,
        "paidByName" => payer_name(advance),
        "reference" => advance.reference
      }
    end)
  end

  defp invoice_history(contract, today) do
    case Repo.query(
           """
           SELECT period_month, invoice_no, total_minor, channel, sent_at, id::text
           FROM public.direct_contract_invoices
           WHERE contract_id = $1::uuid
           """,
           [elem(Ecto.UUID.dump(contract.id), 1)]
         ) do
      {:ok, %{rows: rows}} ->
        by_month =
          Map.new(rows, fn [month, number, total, channel, sent_at, id] ->
            {month,
             %{invoice_no: number, total_minor: total, channel: channel, sent_at: sent_at, id: id}}
          end)

        Enum.map(Calendar.invoice_months(contract.created_at, today), fn month ->
          invoice = Map.get(by_month, month)

          %{
            "month" => Calendar.month_key(month),
            "monthLabel" => Calendar.month_label(month),
            "invoiceNo" => invoice && invoice.invoice_no,
            "amountMinor" => (invoice && invoice.total_minor) || contract.monthly_fee_minor,
            "status" => invoice_status(invoice, month, today),
            "id" => invoice && invoice.id
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp invoice_status(nil, month, today) do
    if Date.compare(month, Calendar.period_start(today)) == :gt,
      do: "not_yet_due",
      else: "not_invoiced"
  end

  defp invoice_status(%{sent_at: nil}, _month, _today), do: "saved"

  defp invoice_status(%{sent_at: sent, channel: "whatsapp"}, _, _) when not is_nil(sent),
    do: "sent_whatsapp"

  defp invoice_status(%{sent_at: sent, channel: "email"}, _, _) when not is_nil(sent),
    do: "sent_email"

  defp invoice_status(%{sent_at: sent}, _, _) when not is_nil(sent), do: "saved"

  defp client_map(contract) do
    %{
      "name" => contract.name,
      "kind" => contract.kind,
      "billingContact" => contract.billing_contact,
      "phone" => contract.phone,
      "email" => contract.email
    }
  end

  defp contract_rows(nil) do
    case Repo.query(contract_sql("WHERE c.status = 'active' ORDER BY cl.name"), []) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &contract_from_row/1)}
      {:error, error} -> map_pg(error)
    end
  end

  defp contract_rows(id) do
    with {:ok, uid} <- dump_uuid(id),
         {:ok, %{rows: rows}} <- Repo.query(contract_sql("WHERE c.id = $1"), [uid]) do
      {:ok, Enum.map(rows, &contract_from_row/1)}
    else
      :error -> {:error, :invalid_request}
      {:error, error} -> map_pg(error)
    end
  end

  defp contract_sql(where) do
    """
    SELECT c.id::text, c.monthly_fee_minor, c.currency, c.status, c.placement_id::text, c.created_at, c.start_on,
           c.include_invoices, cl.name, cl.kind, cl.billing_contact, cl.phone, cl.email,
           c.provider_signer_name, c.provider_signed_at, c.provider_signature
    FROM public.direct_contracts c
    JOIN public.direct_contract_clients cl ON cl.id = c.client_id
    #{where}
    """
  end

  defp contract_from_row([
         id,
         fee,
         currency,
         status,
         placement_id,
         created_at,
         start_on,
         include_invoices,
         name,
         kind,
         contact,
         phone,
         email,
         provider_signer_name,
         provider_signed_at,
         provider_signature
       ]) do
    %{
      id: id,
      monthly_fee_minor: fee,
      currency: currency || "GHS",
      status: status,
      placement_id: placement_id,
      created_at: created_at,
      start_on: start_on,
      include_invoices: include_invoices,
      name: name,
      kind: kind,
      billing_contact: contact,
      phone: phone,
      email: email,
      provider_signer_name: provider_signer_name,
      provider_signed_at: provider_signed_at,
      provider_signature: provider_signature
    }
  end

  defp assignments_for([], _month), do: %{}

  defp assignments_for(contract_ids, month) do
    ids = Enum.map(contract_ids, &elem(Ecto.UUID.dump(&1), 1))
    start = month
    ending = Calendar.period_end(month)

    case Repo.query(
           """
           SELECT a.contract_id::text, a.id::text, a.worker_id::text,
                  COALESCE(NULLIF(btrim(p.fullname), ''), NULLIF(btrim(u.email), ''), 'Worker'),
                  u.phone, w.balance_subunit, a.role_label, a.monthly_pay_minor, a.client_rate_minor,
                  a.weekly_advance_minor, a.advance_weekday, a.advance_mode, a.status, a.ended_on
           FROM public.direct_contract_assignments a
           JOIN public.users u ON u.id = a.worker_id
           LEFT JOIN public.profiles p ON p.id = u.id
           LEFT JOIN public.wallets w ON w.user_id = u.id
           WHERE a.contract_id = ANY($1::uuid[])
             AND (a.created_at AT TIME ZONE 'UTC')::date <= $3
             AND (a.status = 'active' OR a.ended_on >= $2)
           ORDER BY a.created_at
           """,
           [ids, start, ending]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.group_by(rows, &hd/1, fn row ->
          [
            _contract_id,
            id,
            worker_id,
            name,
            phone,
            balance,
            role,
            pay,
            rate,
            weekly,
            weekday,
            mode,
            status,
            ended_on
          ] = row

          %{
            id: id,
            worker_id: worker_id,
            worker_name: name,
            phone: phone,
            wallet_balance_minor: balance,
            role_label: role,
            monthly_pay_minor: pay,
            client_rate_minor: rate,
            weekly_advance_minor: weekly,
            advance_weekday: weekday,
            advance_mode: mode,
            status: status,
            ended_on: ended_on
          }
        end)

      {:error, error} ->
        Logger.error("contract assignments failed: #{inspect(error)}")
        %{}
    end
  end

  defp advances_for([], _month), do: %{}

  defp advances_for(contract_ids, month) do
    ids = Enum.map(contract_ids, &elem(Ecto.UUID.dump(&1), 1))

    case Repo.query(
           """
           SELECT adv.contract_id::text, adv.assignment_id::text, adv.id::text, adv.week_on, adv.amount_minor,
                  adv.paid_via, adv.reference,
                  COALESCE(NULLIF(btrim(pp.fullname), ''), NULLIF(btrim(pu.email), '')),
                  COALESCE(NULLIF(btrim(wp.fullname), ''), NULLIF(btrim(wu.email), ''), 'Worker')
           FROM public.direct_contract_advances adv
           JOIN public.users wu ON wu.id = adv.worker_id
           LEFT JOIN public.profiles wp ON wp.id = wu.id
           LEFT JOIN public.users pu ON pu.id = adv.paid_by
           LEFT JOIN public.profiles pp ON pp.id = pu.id
           WHERE adv.contract_id = ANY($1::uuid[])
             AND adv.week_on >= $2 AND adv.week_on <= $3
           ORDER BY adv.week_on DESC, adv.created_at DESC
           """,
           [ids, month, Calendar.period_end(month)]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.group_by(rows, &hd/1, fn [
                                        _,
                                        assignment_id,
                                        id,
                                        week_on,
                                        amount,
                                        via,
                                        reference,
                                        payer,
                                        worker
                                      ] ->
          %{
            id: id,
            assignment_id: assignment_id,
            week_on: week_on,
            amount_minor: amount,
            paid_via: via,
            reference: reference,
            paid_by_name: payer,
            worker_name: worker
          }
        end)
        |> Map.new(fn {contract_id, list} -> {contract_id, list} end)

      {:error, error} ->
        Logger.error("contract advances failed: #{inspect(error)}")
        %{}
    end
  end

  defp invoices_for([], _month), do: %{}

  defp invoices_for(ids, month) do
    dumped = Enum.map(ids, &elem(Ecto.UUID.dump(&1), 1))

    case Repo.query(
           """
           SELECT contract_id::text, invoice_no, channel, sent_at
           FROM public.direct_contract_invoices
           WHERE contract_id = ANY($1::uuid[]) AND period_month = $2
           """,
           [dumped, month]
         ) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [id, number, channel, sent_at] ->
          {id, %{invoice_no: number, channel: channel, sent_at: sent_at}}
        end)

      {:error, error} ->
        Logger.error("contract invoices failed: #{inspect(error)}")
        %{}
    end
  end

  defp closed_contracts([], _month), do: MapSet.new()

  defp closed_contracts(ids, month) do
    dumped = Enum.map(ids, &elem(Ecto.UUID.dump(&1), 1))

    case Repo.query(
           """
           SELECT contract_id::text
           FROM public.direct_contract_paydays
           WHERE contract_id = ANY($1::uuid[]) AND period_month = $2
           """,
           [dumped, month]
         ) do
      {:ok, %{rows: rows}} -> MapSet.new(Enum.map(rows, &hd/1))
      {:error, _} -> MapSet.new()
    end
  end

  defp due_weeks(contract_uid, month, today \\ Calendar.today(), mode \\ :any) do
    filter =
      case contract_uid do
        nil -> ""
        _ -> "AND a.contract_id = $3"
      end

    mode_sql = if mode == :automatic, do: "AND a.advance_mode = 'automatic'", else: ""

    params =
      if contract_uid,
        do: [month, Calendar.period_end(month), contract_uid],
        else: [month, Calendar.period_end(month)]

    case Repo.query(
           """
           SELECT a.id::uuid, a.advance_weekday, a.ended_on
           FROM public.direct_contract_assignments a
           JOIN public.direct_contracts c ON c.id = a.contract_id
           WHERE c.status = 'active'
             AND a.status = 'active'
             AND a.weekly_advance_minor IS NOT NULL
             AND (a.created_at AT TIME ZONE 'UTC')::date <= $2
             #{mode_sql}
             #{filter}
             AND NOT EXISTS (
               SELECT 1 FROM public.direct_contract_paydays p
               WHERE p.contract_id = a.contract_id AND p.period_month = $1
             )
           """,
           params
         ) do
      {:ok, %{rows: rows}} ->
        paid = paid_weeks(Enum.map(rows, fn [id, _, _] -> id end), month)

        weeks =
          Enum.flat_map(rows, fn [id, weekday, ended_on] ->
            id
            |> uuid_text()
            |> then(fn text_id ->
              month
              |> Calendar.weekday_dates(weekday)
              |> Enum.filter(fn date ->
                if mode == :automatic do
                  Date.compare(date, today) == :eq
                else
                  Date.compare(date, today) != :gt
                end
              end)
              |> Enum.filter(&(ended_on == nil or Date.compare(&1, ended_on) != :gt))
              |> Enum.reject(&MapSet.member?(paid, {text_id, &1}))
              |> Enum.map(&{id, &1})
            end)
          end)

        {:ok, weeks}

      {:error, error} ->
        map_pg(error)
    end
  end

  defp paid_weeks([], _month), do: MapSet.new()

  defp paid_weeks(assignment_ids, month) do
    case Repo.query(
           """
           SELECT assignment_id::text, week_on
           FROM public.direct_contract_advances
           WHERE assignment_id = ANY($1::uuid[])
             AND week_on >= $2 AND week_on <= $3
           """,
           [assignment_ids, month, Calendar.period_end(month)]
         ) do
      {:ok, %{rows: rows}} -> MapSet.new(Enum.map(rows, fn [id, week] -> {id, week} end))
      {:error, _} -> MapSet.new()
    end
  end

  defp pay_each(admin_uid, weeks) do
    Enum.reduce(weeks, {:ok, %{"paidCount" => 0, "totalMinor" => 0}}, fn {assignment_uid, week},
                                                                         acc ->
      case acc do
        {:ok, totals} ->
          case with_admin(admin_uid, fn ->
                 pay_locked(admin_uid, nil, assignment_uid, week, :manual)
               end) do
            {:ok, paid} ->
              {:ok,
               %{
                 "paidCount" => totals["paidCount"] + 1,
                 "totalMinor" => totals["totalMinor"] + paid["amountMinor"]
               }}

            {:error, :advance_already_paid} ->
              {:ok, totals}

            {:error, reason} ->
              if totals["paidCount"] > 0, do: {:ok, totals}, else: {:error, reason}
          end

        other ->
          other
      end
    end)
  end

  defp automatic_one({assignment_uid, week}) do
    transact(fn ->
      case Repo.query("SELECT set_config('mithril.contract_advance', 'automatic', true)", []) do
        {:ok, _} -> pay_locked(nil, nil, assignment_uid, week, :automatic)
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp pay_locked(admin_uid, expected_contract_uid, assignment_uid, week, via) do
    today = Calendar.today()
    month = Calendar.period_start(week)

    assignment =
      case fetch!(
             """
             SELECT a.id, a.contract_id, a.worker_id, a.status, a.weekly_advance_minor, a.advance_weekday,
                    a.ended_on, cl.name
             FROM public.direct_contract_assignments a
             JOIN public.direct_contracts c ON c.id = a.contract_id
             JOIN public.direct_contract_clients cl ON cl.id = c.client_id
             WHERE a.id = $1
             FOR UPDATE OF a
             """,
             [assignment_uid]
           ).rows do
        [row] -> row
        [] -> Repo.rollback(:assignment_not_found)
      end

    [id, contract_uid, worker_uid, status, amount, weekday, ended_on, client_name] = assignment

    if expected_contract_uid && expected_contract_uid != contract_uid,
      do: Repo.rollback(:assignment_not_found)

    fetch!("SELECT id FROM public.direct_contracts WHERE id = $1 FOR UPDATE", [contract_uid])

    cond do
      status != "active" -> Repo.rollback(:assignment_ended)
      amount == nil or weekday == nil -> Repo.rollback(:advance_not_due)
      date_weekday(week) != weekday -> Repo.rollback(:advance_not_due)
      Date.compare(week, today) == :gt -> Repo.rollback(:advance_not_due)
      ended_on && Date.compare(week, ended_on) == :gt -> Repo.rollback(:assignment_ended)
      payday_closed?(contract_uid, month) -> Repo.rollback(:payday_already_run)
      true -> :ok
    end

    description = "Contract weekly advance — #{client_name} — #{Calendar.short_date(week)}"
    credit = credit_wallet(worker_uid, amount, admin_uid, description)
    reference = next_reference()

    %{rows: [[advance_id]]} =
      fetch!(
        """
        INSERT INTO public.direct_contract_advances (
          assignment_id, contract_id, worker_id, week_on, amount_minor, paid_via, paid_by, reference, wallet_transaction_id
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        RETURNING id::text
        """,
        [
          id,
          contract_uid,
          worker_uid,
          week,
          amount,
          Atom.to_string(via),
          admin_uid,
          reference,
          credit.transaction_id
        ]
      )

    %{
      "id" => advance_id,
      "reference" => reference,
      "amountMinor" => amount,
      "newBalanceMinor" => credit.balance,
      "weekOn" => Date.to_iso8601(week)
    }
  end

  defp close_payday(admin_uid, contract_uid, month) do
    ending = Calendar.period_end(month)

    case fetch!("SELECT id, client_id FROM public.direct_contracts WHERE id = $1 FOR UPDATE", [
           contract_uid
         ]).rows do
      [] -> Repo.rollback(:contract_not_found)
      [_] -> :ok
    end

    if payday_closed?(contract_uid, month), do: Repo.rollback(:payday_already_run)

    %{rows: [[client_name]]} =
      fetch!(
        """
        SELECT cl.name
        FROM public.direct_contract_clients cl
        JOIN public.direct_contracts c ON c.client_id = cl.id
        WHERE c.id = $1
        """,
        [contract_uid]
      )

    %{rows: assignments} =
      fetch!(
        """
        SELECT a.id, a.worker_id, a.monthly_pay_minor,
               COALESCE(NULLIF(btrim(p.fullname), ''), 'Worker')
        FROM public.direct_contract_assignments a
        JOIN public.users u ON u.id = a.worker_id
        LEFT JOIN public.profiles p ON p.id = u.id
        WHERE a.contract_id = $1
          AND (a.created_at AT TIME ZONE 'UTC')::date <= $3
          AND (a.status = 'active' OR a.ended_on >= $2)
        ORDER BY a.created_at
        FOR UPDATE OF a
        """,
        [contract_uid, month, ending]
      )

    lines =
      Enum.map(assignments, fn [assignment_uid, worker_uid, gross, name] ->
        %{rows: [[advances]]} =
          fetch!(
            """
            SELECT COALESCE(SUM(amount_minor), 0)
            FROM public.direct_contract_advances
            WHERE assignment_id = $1 AND week_on >= $2 AND week_on <= $3
            """,
            [assignment_uid, month, ending]
          )

        advances = int(advances)
        net = Calendar.net_minor(gross, advances)

        tx_id =
          if net > 0 do
            credit_wallet(
              worker_uid,
              net,
              admin_uid,
              "Contract payday — #{client_name} — #{Calendar.month_label(month)}"
            ).transaction_id
          end

        %{
          assignment_id: assignment_uid,
          worker_uid: worker_uid,
          name: name,
          gross: gross,
          advances: advances,
          net: net,
          transaction_id: tx_id
        }
      end)

    total = Enum.reduce(lines, 0, &(&1.net + &2))

    %{rows: [[payday_id]]} =
      fetch!(
        """
        INSERT INTO public.direct_contract_paydays (contract_id, period_month, paid_by, total_net_minor)
        VALUES ($1, $2, $3, $4)
        RETURNING id
        """,
        [contract_uid, month, admin_uid, total]
      )

    Enum.each(lines, fn line ->
      fetch!(
        """
        INSERT INTO public.direct_contract_payday_lines (
          payday_id, assignment_id, gross_minor, advances_minor, net_minor, wallet_transaction_id
        ) VALUES ($1, $2, $3, $4, $5, $6)
        """,
        [payday_id, line.assignment_id, line.gross, line.advances, line.net, line.transaction_id]
      )
    end)

    %{
      "contractId" => uuid_text(contract_uid),
      "month" => Calendar.month_key(month),
      "totalNetMinor" => total,
      "lines" =>
        Enum.map(lines, fn line ->
          %{
            "workerName" => line.name,
            "grossMinor" => line.gross,
            "advancesMinor" => line.advances,
            "netMinor" => line.net
          }
        end)
    }
  end

  defp ensure_invoice(admin_uid, contract_uid, month, style) do
    case Repo.query(
           """
           SELECT i.id::text, i.invoice_no, i.public_token, i.total_minor, i.issued_on, i.due_on,
                  i.sent_at, i.channel, cl.name, cl.billing_contact, cl.phone, cl.email
           FROM public.direct_contract_invoices i
           JOIN public.direct_contracts c ON c.id = i.contract_id
           JOIN public.direct_contract_clients cl ON cl.id = c.client_id
           WHERE i.contract_id = $1 AND i.period_month = $2
           """,
           [contract_uid, month]
         ) do
      {:ok,
       %{
         rows: [
           [id, number, token, total, issued, due, sent_at, channel, name, contact, phone, email]
         ]
       }} ->
        if sent_at do
          {:error, :invoice_already_sent}
        else
          {:ok,
           invoice_payload(
             id,
             number,
             token,
             total,
             issued,
             due,
             channel,
             name,
             contact,
             phone,
             email,
             month
           )}
        end

      {:ok, %{rows: []}} ->
        insert_invoice(admin_uid, contract_uid, month, style)

      {:error, error} ->
        map_pg(error)
    end
  end

  defp insert_invoice(admin_uid, contract_uid, month, style) do
    transact(fn ->
      case fetch!(
             """
             SELECT c.monthly_fee_minor, cl.name, cl.billing_contact, cl.phone, cl.email
             FROM public.direct_contracts c
             JOIN public.direct_contract_clients cl ON cl.id = c.client_id
             WHERE c.id = $1
             FOR UPDATE OF c
             """,
             [contract_uid]
           ).rows do
        [] ->
          Repo.rollback(:contract_not_found)

        [[fee, name, contact, phone, email]] ->
          workers =
            Map.get(
              assignments_for([uuid_text(contract_uid)], month),
              uuid_text(contract_uid),
              []
            )

          lines = invoice_lines(style, fee, workers, month)
          number = next_invoice_no(month.year)
          token = random_token()
          issued = Calendar.today()
          due = Date.add(issued, 7)

          %{rows: [[id]]} =
            fetch!(
              """
              INSERT INTO public.direct_contract_invoices (
                contract_id, period_month, invoice_no, public_token, issued_on, due_on, style, total_minor, created_by
              ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
              RETURNING id
              """,
              [contract_uid, month, number, token, issued, due, style, fee, admin_uid]
            )

          Enum.with_index(lines, fn line, index ->
            fetch!(
              """
              INSERT INTO public.direct_contract_invoice_lines (invoice_id, position, description, amount_minor, assignment_id)
              VALUES ($1, $2, $3, $4, $5)
              """,
              [id, index, line.description, line.amount, line.assignment_id]
            )
          end)

          invoice_payload(
            uuid_text(id),
            number,
            token,
            fee,
            issued,
            due,
            nil,
            name,
            contact,
            phone,
            email,
            month
          )
      end
    end)
  end

  defp invoice_lines("one_line", fee, workers, month) do
    count = length(workers)
    label = if count == 1, do: "1 worker", else: "#{count} workers"

    [
      %{
        description: "Monthly service fee · #{label} · #{Calendar.month_label(month)}",
        amount: fee,
        assignment_id: nil
      }
    ]
  end

  defp invoice_lines("per_worker", fee, workers, month) do
    lines =
      workers
      |> Enum.filter(&(&1.client_rate_minor > 0))
      |> Enum.map(fn worker ->
        %{
          description:
            "#{worker.role_label} service · #{worker.worker_name} · #{Calendar.month_label(month)}",
          amount: worker.client_rate_minor,
          assignment_id: elem(Ecto.UUID.dump(worker.id), 1)
        }
      end)

    total = Enum.reduce(lines, 0, &(&1.amount + &2))
    if lines == [] or total != fee, do: Repo.rollback(:client_rates_mismatch)
    lines
  end

  defp invoice_payload(
         id,
         number,
         token,
         total,
         issued,
         due,
         channel,
         name,
         contact,
         phone,
         email,
         month
       ) do
    %{
      "id" => id,
      "invoiceNo" => number,
      "publicToken" => token,
      "totalMinor" => total,
      "issuedOn" => Date.to_iso8601(issued),
      "dueOn" => Date.to_iso8601(due),
      "channel" => channel,
      "billToName" => name,
      "billingContact" => contact,
      "phone" => phone,
      "email" => email,
      "month" => Calendar.month_key(month),
      "project" => Calendar.month_label(month),
      "viewUrl" => view_url(token)
    }
  end

  defp public_invoice(_token, [
         number,
         issued,
         due,
         total,
         currency,
         name,
         contact,
         phone,
         email,
         month
       ]) do
    %{rows: line_rows} =
      Repo.query!(
        """
        SELECT description, amount_minor
        FROM public.direct_contract_invoice_lines l
        JOIN public.direct_contract_invoices i ON i.id = l.invoice_id
        WHERE i.invoice_no = $1
        ORDER BY l.position
        """,
        [number]
      )

    %{
      "invoiceNo" => number,
      "issuedOn" => Date.to_iso8601(issued),
      "dueOn" => Date.to_iso8601(due),
      "totalMinor" => total,
      "currency" => currency,
      "billToName" => name,
      "billingContact" => contact,
      "billToPhone" => phone,
      "billToEmail" => email,
      "project" => Calendar.month_label(month),
      "notes" => "Worker advances are not included in this invoice.",
      "lines" =>
        Enum.map(line_rows, fn [description, amount] ->
          %{"description" => description, "amountMinor" => amount}
        end)
    }
  end

  defp mark_sent(invoice_id, channel) do
    case dump_uuid(invoice_id) do
      {:ok, uid} ->
        case Repo.query(
               """
               UPDATE public.direct_contract_invoices
               SET channel = $2, sent_at = now(), sending_at = NULL
               WHERE id = $1 AND sent_at IS NULL AND sending_at IS NOT NULL
               RETURNING invoice_no, total_minor, channel
               """,
               [uid, channel]
             ) do
          {:ok, %{rows: [[number, total, saved_channel]]}} ->
            {:ok,
             %{
               "invoiceNo" => number,
               "totalMinor" => total,
               "channel" => saved_channel,
               "sent" => true
             }}

          {:ok, %{rows: []}} ->
            {:error, :invoice_already_sent}

          {:error, error} ->
            map_pg(error)
        end

      :error ->
        {:error, :invalid_request}
    end
  end

  defp claim_invoice_delivery(invoice_id) do
    with {:ok, uid} <- dump_uuid(invoice_id) do
      case Repo.query(
             """
             UPDATE public.direct_contract_invoices
             SET sending_at = now()
             WHERE id = $1 AND sent_at IS NULL AND sending_at IS NULL
             RETURNING id
             """,
             [uid]
           ) do
        {:ok, %{rows: [[_]]}} -> :ok
        {:ok, %{rows: []}} -> {:error, :invoice_delivery_in_progress}
        {:error, error} -> map_pg(error)
      end
    end
  end

  defp deliver_claimed_invoice(admin_uid, invoice, channel) do
    case deliver(admin_uid, invoice, channel) do
      :ok ->
        :ok

      {:error, _} = error ->
        # A failed provider call must not permanently block an invoice from retrying.
        {:ok, uid} = dump_uuid(invoice["id"])

        Repo.query!(
          "UPDATE public.direct_contract_invoices SET sending_at = NULL WHERE id = $1 AND sent_at IS NULL",
          [uid]
        )

        error
    end
  end

  defp deliver(admin_uid, invoice, "whatsapp") do
    phone = invoice["phone"]

    if is_binary(phone) and String.trim(phone) != "" do
      InvoiceTemplate.deliver(
        admin_uid,
        invoice,
        phone,
        invoice_message(invoice),
        DirectAdminInvoices.money(invoice["totalMinor"])
      )
    else
      {:error, :missing_phone}
    end
  end

  defp deliver(_admin_uid, invoice, "email") do
    email = invoice["email"]

    if is_binary(email) and email != "" do
      send_email(invoice)
    else
      {:error, :missing_email}
    end
  end

  defp deliver(_, _, _), do: {:error, :invalid_request}

  defp send_email(invoice) do
    post_email(
      invoice["email"],
      "Instaclean invoice #{invoice["invoiceNo"]}",
      email_html(invoice)
    )
  end

  defp post_email(to, subject, html) do
    api_key = Application.get_env(:mithril, :resend_api_key, "") |> to_string() |> String.trim()

    if api_key == "" do
      {:error, :email_not_configured}
    else
      body = %{
        from:
          Application.get_env(
            :mithril,
            :resend_from,
            "Instaclean <noreply@update.tryinstaclean.com>"
          ),
        to: [to],
        subject: subject,
        html: html
      }

      case Req.post(resend_url(), resend_options(body, api_key)) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _ -> {:error, :email_delivery_failed}
      end
    end
  end

  defp invoice_message(invoice) do
    contact = invoice["billingContact"]
    attention = if is_binary(contact) and contact != "", do: "Attn. #{contact}\n", else: ""

    """
    Instaclean invoice #{invoice["invoiceNo"]}
    #{invoice["billToName"]}
    #{attention}#{invoice["project"]}: #{Calendar.format_ghs(invoice["totalMinor"])}
    Due #{invoice["dueOn"]}
    #{invoice["viewUrl"]}
    """
    |> String.trim()
  end

  defp email_html(invoice) do
    """
    <p>Invoice #{html_escape(invoice["invoiceNo"])} for #{html_escape(invoice["billToName"])}.</p>
    <p>#{html_escape(invoice["project"])}: #{html_escape(Calendar.format_ghs(invoice["totalMinor"]))}</p>
    <p>Due #{html_escape(invoice["dueOn"])}</p>
    <p><a href="#{html_escape(invoice["viewUrl"])}">View invoice</a></p>
    """
  end

  defp credit_wallet(worker_uid, amount, admin_uid, description) do
    %{rows: [[payload]]} =
      fetch!(
        """
        SELECT public.record_contract_wallet_credit($1::uuid, $2::integer, $3::uuid, $4::text)
        """,
        [worker_uid, amount, admin_uid, description]
      )

    %{
      transaction_id: dump_any_uuid(payload["wallet_transaction_id"]),
      balance: payload["new_balance_subunit"]
    }
  end

  defp dump_any_uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} ->
        dumped

      :error ->
        case Ecto.UUID.load(value) do
          {:ok, _} -> value
          :error -> Repo.rollback(:database_unavailable)
        end
    end
  end

  defp dump_any_uuid(_), do: Repo.rollback(:database_unavailable)

  defp next_reference do
    %{rows: [[number]]} = fetch!("SELECT nextval('public.direct_contract_wallet_ref_seq')", [])
    "WLT-#{number}"
  end

  defp prepare_letter(admin_uid, contract_uid, claim?) do
    transact(fn ->
      case fetch!(
             """
             SELECT c.monthly_fee_minor, c.currency, c.created_at, c.start_on, c.include_invoices,
                    cl.name, cl.billing_contact, cl.phone, cl.email
             FROM public.direct_contracts c
             JOIN public.direct_contract_clients cl ON cl.id = c.client_id
             WHERE c.id = $1
             FOR UPDATE OF c
             """,
             [contract_uid]
           ).rows do
        [] ->
          Repo.rollback(:contract_not_found)

        [[fee, currency, created_at, start_on, include_invoices, name, contact, phone, email]] ->
          workers = letter_workers!(contract_uid)
          if workers == [], do: Repo.rollback(:letter_needs_worker)

          contract = %{
            monthly_fee_minor: fee,
            currency: currency,
            created_at: created_at,
            start_on: start_on,
            include_invoices: include_invoices,
            name: name,
            billing_contact: contact,
            phone: phone,
            email: email
          }

          preview = Letter.preview(contract, workers)
          issued = Calendar.today()

          case fetch!(
                 "SELECT 1 FROM public.direct_contract_letters WHERE contract_id = $1 AND sending_at IS NOT NULL AND sent_at IS NULL",
                 [contract_uid]
               ).rows do
            [] -> :ok
            _ -> Repo.rollback(:letter_in_progress)
          end

          letter = write_letter(admin_uid, contract_uid, preview, issued)
          sync_worker_letters(admin_uid, contract_uid, letter["id"], contract, workers, issued)

          if claim? do
            {:ok, letter_uid} = dump_uuid(letter["id"])

            fetch!(
              "UPDATE public.direct_contract_letters SET sending_at = now() WHERE id = $1 AND sent_at IS NULL AND sending_at IS NULL",
              [letter_uid]
            )
          end

          letter
      end
    end)
  end

  defp letter_result(letter, channel, sent) do
    %{
      "letterNo" => letter["letterNo"],
      "channel" => channel,
      "sent" => sent,
      "viewUrl" => letter["viewUrl"]
    }
  end

  defp write_letter(admin_uid, contract_uid, preview, issued) do
    params = letter_write_params(preview, issued)

    case fetch!(
           """
           SELECT id, letter_no, public_token
           FROM public.direct_contract_letters
           WHERE contract_id = $1 AND sent_at IS NULL
           ORDER BY created_at DESC
           LIMIT 1
           FOR UPDATE
           """,
           [contract_uid]
         ).rows do
      [[id, number, token]] ->
        fetch!(
          """
          UPDATE public.direct_contract_letters
          SET issued_on = $2, start_on = $3, monthly_fee_minor = $4, currency = $5,
              client_name = $6, billing_contact = $7, phone = $8, email = $9,
              preamble = $10, workers = $11::jsonb, clauses = $12::jsonb,
              provider_signer_name = COALESCE(provider_signer_name, $13),
              provider_signed_at = COALESCE(provider_signed_at, $14),
              provider_signature = COALESCE(provider_signature, $15)
          WHERE id = $1
          """,
          [id | params] ++ current_provider_signature(contract_uid)
        )

        letter_payload(id, number, token, preview)

      [] ->
        number = next_letter_no(issued.year)
        token = random_token()

        %{rows: [[id]]} =
          fetch!(
            """
            INSERT INTO public.direct_contract_letters (
              contract_id, letter_no, public_token, issued_on, start_on, monthly_fee_minor, currency,
              client_name, billing_contact, phone, email, preamble, workers, clauses, created_by,
              provider_signer_name, provider_signed_at, provider_signature
            ) VALUES (
              $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13::jsonb, $14::jsonb, $15, $16, $17, $18
            )
            RETURNING id
            """,
            [contract_uid, number, token | params] ++
              [admin_uid | current_provider_signature(contract_uid)]
          )

        letter_payload(id, number, token, preview)
    end
  end

  defp letter_write_params(preview, issued) do
    [
      issued,
      Date.from_iso8601!(preview["startOn"]),
      preview["monthlyFeeMinor"],
      preview["currency"],
      preview["clientName"],
      preview["billingContact"],
      preview["phone"],
      preview["email"],
      preview["preamble"],
      preview["workers"],
      preview["clauses"]
    ]
  end

  defp letter_payload(id, number, token, preview) do
    %{
      "id" => uuid_text(id),
      "letterNo" => number,
      "publicToken" => token,
      "phone" => preview["phone"],
      "email" => preview["email"],
      "clientName" => preview["clientName"],
      "billingContact" => preview["billingContact"],
      "preamble" => preview["preamble"],
      "monthlyFeeMinor" => preview["monthlyFeeMinor"],
      "workers" => preview["workers"],
      "viewUrl" => letter_url(token)
    }
  end

  defp public_letter_payload([
         number,
         issued,
         start_on,
         fee,
         currency,
         name,
         contact,
         phone,
         email,
         preamble,
         workers,
         clauses,
         active,
         provider_name,
         provider_signed_at,
         provider_signature,
         client_name_signed,
         client_signed_at,
         client_signature
       ]) do
    %{
      "letterNo" => number,
      "issuedOn" => Date.to_iso8601(issued),
      "startOn" => Date.to_iso8601(start_on),
      "monthlyFeeMinor" => fee,
      "currency" => currency,
      "clientName" => name,
      "billingContact" => contact,
      "phone" => phone,
      "email" => email,
      "kind" => "client",
      "preamble" => preamble,
      "workers" => json_list(workers),
      "clauses" => json_list(clauses),
      "active" => active == true,
      "providerSignature" => signature_map(provider_name, provider_signed_at, provider_signature),
      "counterpartySignature" =>
        signature_map(client_name_signed, client_signed_at, client_signature)
    }
  end

  defp worker_letter_payload([
         number,
         issued,
         start_on,
         pay,
         advance,
         currency,
         worker_name,
         role,
         client_name,
         phone,
         email,
         preamble,
         clauses,
         active,
         provider_name,
         provider_signed_at,
         provider_signature,
         worker_signed_name,
         worker_signed_at,
         worker_signature
       ]) do
    %{
      "kind" => "worker",
      "letterNo" => number,
      "issuedOn" => Date.to_iso8601(issued),
      "startOn" => Date.to_iso8601(start_on),
      "monthlyFeeMinor" => pay,
      "monthlyPayMinor" => pay,
      "weeklyAdvanceMinor" => advance,
      "currency" => currency,
      "clientName" => client_name,
      "workerName" => worker_name,
      "roleLabel" => role,
      "billingContact" => nil,
      "phone" => phone,
      "email" => email,
      "preamble" => preamble,
      "workers" => [],
      "clauses" => json_list(clauses),
      "active" => active == true,
      "providerSignature" => signature_map(provider_name, provider_signed_at, provider_signature),
      "counterpartySignature" =>
        signature_map(worker_signed_name, worker_signed_at, worker_signature)
    }
  end

  defp json_list(value) when is_list(value), do: value

  defp json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp json_list(_), do: []

  defp active_letter_workers(contract_id) do
    case dump_uuid(contract_id) do
      {:ok, uid} ->
        case Repo.query(letter_worker_sql(), [uid]) do
          {:ok, %{rows: rows}} ->
            letter_worker_rows(rows)

          {:error, error} ->
            Logger.error("contract letter workers failed: #{inspect(error)}")
            []
        end

      :error ->
        []
    end
  end

  defp letter_workers!(contract_uid) do
    fetch!(letter_worker_sql(), [contract_uid]).rows |> letter_worker_rows()
  end

  defp letter_worker_sql do
    """
    SELECT a.id, a.worker_id, a.role_label,
           COALESCE(NULLIF(btrim(p.fullname), ''), NULLIF(btrim(u.email), ''), 'Worker'),
           a.monthly_pay_minor, COALESCE(a.weekly_advance_minor, 0), u.phone, u.email, a.created_at
    FROM public.direct_contract_assignments a
    JOIN public.users u ON u.id = a.worker_id
    LEFT JOIN public.profiles p ON p.id = u.id
    WHERE a.contract_id = $1 AND a.status = 'active'
    ORDER BY a.created_at, a.id
    """
  end

  defp letter_worker_rows(rows) do
    Enum.map(rows, fn [
                        assignment_id,
                        worker_id,
                        role,
                        name,
                        pay,
                        advance,
                        phone,
                        email,
                        started_at
                      ] ->
      %{
        assignment_id: uuid_text(assignment_id),
        worker_id: uuid_text(worker_id),
        role_label: role,
        worker_name: name,
        started_at: started_at,
        monthly_pay_minor: pay,
        weekly_advance_minor: advance || 0,
        phone: phone,
        email: email
      }
    end)
  end

  defp letter_history(contract_id) do
    case dump_uuid(contract_id) do
      {:ok, uid} ->
        case Repo.query(
               """
               SELECT id::text, letter_no, issued_on, channel, sent_at, public_token,
                      client_signer_name, client_signed_at
               FROM public.direct_contract_letters
               WHERE contract_id = $1
               ORDER BY created_at DESC, id DESC
               """,
               [uid]
             ) do
          {:ok, %{rows: rows}} ->
            Enum.map(rows, fn [id, number, issued, channel, sent_at, token, signer, signed_at] ->
              %{
                "id" => id,
                "letterNo" => number,
                "issuedOn" => Date.to_iso8601(issued),
                "status" => letter_status(sent_at, channel),
                "channel" => channel,
                "viewUrl" => letter_url(token),
                "clientSigned" => not is_nil(signed_at),
                "clientSignerName" => if(is_nil(signed_at), do: nil, else: signer)
              }
            end)

          {:error, error} ->
            Logger.error("contract letters failed: #{inspect(error)}")
            []
        end

      :error ->
        []
    end
  end

  defp letter_status(nil, _), do: "saved"
  defp letter_status(_sent_at, "whatsapp"), do: "sent_whatsapp"
  defp letter_status(_sent_at, "email"), do: "sent_email"
  defp letter_status(_sent_at, _), do: "saved"

  defp mark_letter_sent(letter_id, channel, token) do
    case dump_uuid(letter_id) do
      {:ok, uid} ->
        case Repo.transaction(fn ->
               case Repo.query(
                      """
                      UPDATE public.direct_contract_letters
                      SET channel = $2, sent_at = now(), sending_at = NULL
                      WHERE id = $1 AND sent_at IS NULL AND sending_at IS NOT NULL
                      RETURNING letter_no, channel
                      """,
                      [uid, channel]
                    ) do
                 {:ok, %{rows: [[number, saved_channel]]}} ->
                   :ok = mark_worker_letters_sent(uid, channel)
                   %{number: number, channel: saved_channel}

                 {:ok, %{rows: []}} ->
                   Repo.rollback(:letter_already_sent)

                 {:error, error} ->
                   Repo.rollback(error)
               end
             end) do
          {:ok, %{number: number, channel: saved_channel}} ->
            {:ok,
             %{
               "letterNo" => number,
               "channel" => saved_channel,
               "sent" => true,
               "viewUrl" => letter_url(token)
             }}

          {:error, reason} when is_atom(reason) ->
            {:error, reason}

          {:error, error} ->
            map_pg(error)
        end

      :error ->
        {:error, :invalid_request}
    end
  end

  defp release_letter_claim(letter_id) do
    with {:ok, uid} <- dump_uuid(letter_id) do
      Repo.query(
        "UPDATE public.direct_contract_letters SET sending_at = NULL WHERE id = $1 AND sent_at IS NULL",
        [uid]
      )
    end
  end

  defp deliver_letter(admin_uid, letter, "whatsapp") do
    phone = letter["phone"]

    if is_binary(phone) and String.trim(phone) != "" do
      ContractLetterTemplate.deliver(
        admin_uid,
        letter,
        phone,
        letter_message(letter),
        DirectAdminInvoices.money(letter["monthlyFeeMinor"])
      )
    else
      {:error, :missing_phone}
    end
  end

  defp deliver_letter(_admin_uid, letter, "email") do
    email = letter["email"]

    if is_binary(email) and email != "" do
      send_letter_email(letter)
    else
      {:error, :missing_email}
    end
  end

  defp deliver_letter(_, _, _), do: {:error, :invalid_request}

  defp send_letter_email(letter) do
    post_email(
      letter["email"],
      "Instaclean service agreement #{letter["letterNo"]}",
      letter_email_html(letter)
    )
  end

  defp letter_message(letter) do
    names =
      Enum.map_join(letter["workers"], "\n", fn worker ->
        "#{worker["roleLabel"]} — #{worker["workerName"]}"
      end)

    """
    Instaclean service agreement #{letter["letterNo"]}
    #{letter["clientName"]}
    Monthly fee #{Calendar.format_ghs(letter["monthlyFeeMinor"])}
    #{names}
    #{letter["viewUrl"]}
    """
    |> String.trim()
  end

  defp letter_email_html(letter) do
    workers =
      Enum.map_join(letter["workers"], "", fn worker ->
        "<li>#{html_escape(worker["roleLabel"])} — #{html_escape(worker["workerName"])}</li>"
      end)

    """
    <p>#{html_escape(letter["preamble"])}</p>
    <ul>#{workers}</ul>
    <p>Monthly fee #{html_escape(Calendar.format_ghs(letter["monthlyFeeMinor"]))}</p>
    <p><a href="#{html_escape(letter["viewUrl"])}">View the service agreement</a></p>
    """
  end

  defp sync_worker_letters(admin_uid, contract_uid, client_letter_id, contract, workers, issued) do
    {:ok, letter_uid} = dump_uuid(client_letter_id)
    drop_retired_worker_letters(letter_uid, workers)

    Enum.each(workers, fn worker ->
      write_worker_letter(admin_uid, contract_uid, letter_uid, contract, worker, issued)
    end)
  end

  defp drop_retired_worker_letters(letter_uid, workers) do
    ids = Enum.map(workers, fn worker -> Ecto.UUID.dump!(worker.assignment_id) end)

    fetch!(
      """
      DELETE FROM public.direct_contract_worker_letters
      WHERE client_letter_id = $1
        AND sent_at IS NULL
        AND NOT (assignment_id = ANY($2::uuid[]))
      """,
      [letter_uid, ids]
    )
  end

  defp write_worker_letter(admin_uid, contract_uid, letter_uid, contract, worker, issued) do
    {:ok, assignment_uid} = dump_uuid(worker.assignment_id)
    {:ok, worker_uid} = dump_uuid(worker.worker_id)
    drafted = Letter.worker_letter(contract, worker)

    case fetch!(
           """
           SELECT id, letter_no, public_token
           FROM public.direct_contract_worker_letters
           WHERE client_letter_id = $1 AND assignment_id = $2 AND sent_at IS NULL
           FOR UPDATE
           """,
           [letter_uid, assignment_uid]
         ).rows do
      [[id, _number, _token]] ->
        fetch!(
          """
          UPDATE public.direct_contract_worker_letters
          SET issued_on = $2, start_on = $3, monthly_pay_minor = $4, weekly_advance_minor = $5,
              currency = $6, worker_name = $7, role_label = $8, client_name = $9,
              phone = $10, email = $11, preamble = $12, clauses = $13::jsonb,
              provider_signer_name = COALESCE(provider_signer_name, $14),
              provider_signed_at = COALESCE(provider_signed_at, $15),
              provider_signature = COALESCE(provider_signature, $16)
          WHERE id = $1
          """,
          [id | worker_letter_params(drafted, issued)] ++ current_provider_signature(contract_uid)
        )

      [] ->
        number = next_letter_no(issued.year)
        token = random_token()

        fetch!(
          """
          INSERT INTO public.direct_contract_worker_letters (
            contract_id, client_letter_id, assignment_id, worker_id, letter_no, public_token,
            issued_on, start_on, monthly_pay_minor, weekly_advance_minor, currency,
            worker_name, role_label, client_name, phone, email, preamble, clauses, created_by,
            provider_signer_name, provider_signed_at, provider_signature
          ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18::jsonb, $19,
            $20, $21, $22
          )
          """,
          [
            contract_uid,
            letter_uid,
            assignment_uid,
            worker_uid,
            number,
            token | worker_letter_params(drafted, issued)
          ] ++ [admin_uid | current_provider_signature(contract_uid)]
        )
    end
  end

  defp worker_letter_params(drafted, issued) do
    [
      issued,
      Date.from_iso8601!(drafted["startOn"]),
      drafted["monthlyPayMinor"],
      drafted["weeklyAdvanceMinor"],
      drafted["currency"],
      drafted["workerName"],
      drafted["roleLabel"],
      drafted["clientName"],
      drafted["phone"],
      drafted["email"],
      drafted["preamble"],
      drafted["clauses"]
    ]
  end

  defp worker_letters_for_account(user_uid) do
    case Repo.query(
           """
           SELECT l.letter_no, l.issued_on, l.start_on, l.monthly_pay_minor, l.weekly_advance_minor, l.currency,
                  l.worker_name, l.role_label, l.client_name, l.phone, l.email, l.preamble, l.clauses,
                  (c.status = 'active' AND a.status = 'active'),
                  l.provider_signer_name, l.provider_signed_at, l.provider_signature,
                  l.worker_signer_name, l.worker_signed_at, l.worker_signature
           FROM public.direct_contract_worker_letters l
           JOIN public.direct_contract_assignments a ON a.id = l.assignment_id
           JOIN public.direct_contracts c ON c.id = l.contract_id
           WHERE l.worker_id = $1 AND l.sent_at IS NOT NULL
           ORDER BY l.sent_at DESC, l.letter_no DESC
           """,
           [user_uid]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, %{"letters" => Enum.map(rows, &worker_letter_payload/1)}}

      {:error, error} ->
        map_pg(error)
    end
  end

  defp worker_letter_history(contract_id) do
    case dump_uuid(contract_id) do
      {:ok, uid} ->
        case Repo.query(
               """
               SELECT id::text, letter_no, issued_on, channel, sent_at, public_token, worker_name, role_label
               FROM public.direct_contract_worker_letters
               WHERE contract_id = $1
               ORDER BY letter_no DESC
               """,
               [uid]
             ) do
          {:ok, %{rows: rows}} ->
            Enum.map(rows, fn [id, number, issued, channel, sent_at, token, worker_name, role] ->
              %{
                "id" => id,
                "letterNo" => number,
                "issuedOn" => Date.to_iso8601(issued),
                "status" => letter_status(sent_at, channel),
                "channel" => channel,
                "viewUrl" => worker_letter_url(token),
                "workerName" => worker_name,
                "roleLabel" => role
              }
            end)

          {:error, error} ->
            Logger.error("worker contract letters failed: #{inspect(error)}")
            []
        end

      :error ->
        []
    end
  end

  defp mark_worker_letters_sent(client_letter_uid, channel) do
    fetch!(
      """
      UPDATE public.direct_contract_worker_letters
      SET channel = $2, sent_at = now()
      WHERE client_letter_id = $1 AND sent_at IS NULL
      """,
      [client_letter_uid, channel]
    )

    :ok
  end

  defp worker_letter_url(token) do
    base =
      Application.get_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")
      |> to_string()
      |> String.trim_trailing("/")

    "#{base}/letters/worker/#{token}"
  end

  defp next_letter_no(year) do
    %{rows: [[number]]} = fetch!("SELECT nextval('public.direct_contract_letter_no_seq')", [])
    "LTR-#{year}-" <> String.pad_leading(Integer.to_string(number), 3, "0")
  end

  defp letter_url(token) do
    base =
      Application.get_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")
      |> to_string()
      |> String.trim_trailing("/")

    "#{base}/letters/contract/#{token}"
  end

  defp next_invoice_no(year) do
    %{rows: [[number]]} = fetch!("SELECT nextval('public.direct_contract_invoice_no_seq')", [])
    "INV-#{year}-" <> String.pad_leading(Integer.to_string(number), 3, "0")
  end

  defp payday_closed?(contract_uid, month) do
    fetch!(
      "SELECT 1 FROM public.direct_contract_paydays WHERE contract_id = $1 AND period_month = $2",
      [
        contract_uid,
        month
      ]
    ).rows != []
  end

  defp week_visible?(date, assignment) do
    assignment.ended_on == nil or Date.compare(date, assignment.ended_on) != :gt
  end

  defp in_month?(date, month) do
    Date.compare(date, month) != :lt and Date.compare(date, Calendar.period_end(month)) != :gt
  end

  defp payer_name(%{paid_via: "automatic"}), do: "Automatic · 06:00"
  defp payer_name(%{paid_by_name: name}) when is_binary(name) and name != "", do: name
  defp payer_name(_), do: "Admin"

  defp with_admin(admin_uid, fun) do
    case DirectAdminActor.with_actor(admin_uid, fun) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> unwrap(reason)
    end
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> unwrap(reason)
    end
  end

  defp fetch!(sql, params) do
    case Repo.query(sql, params) do
      {:ok, result} -> result
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp unwrap(%Postgrex.Error{} = error), do: map_pg(error)
  defp unwrap(reason) when is_atom(reason), do: {:error, reason}
  defp unwrap(reason), do: {:error, reason}

  defp map_pg(%Postgrex.Error{postgres: %{code: :unique_violation, constraint: constraint}}) do
    cond do
      constraint && String.contains?(constraint, "assignment_week") ->
        {:error, :advance_already_paid}

      constraint && String.contains?(constraint, "paydays") ->
        {:error, :payday_already_run}

      constraint && String.contains?(constraint, "invoices_contract_month") ->
        {:error, :invoice_already_sent}

      constraint && String.contains?(constraint, "one_active_worker") ->
        {:error, :worker_already_assigned}

      true ->
        {:error, :conflict}
    end
  end

  defp map_pg(%Postgrex.Error{postgres: %{message: message}} = error) when is_binary(message) do
    cond do
      String.contains?(message, "worker_not_found") ->
        {:error, :worker_not_found}

      String.contains?(message, "wallet_not_found") ->
        {:error, :wallet_not_found}

      String.contains?(message, "invalid_amount") ->
        {:error, :invalid_amount}

      String.contains?(message, "unsupported_currency") ->
        {:error, :unsupported_currency}

      String.contains?(message, "amount_too_large") ->
        {:error, :amount_too_large}

      String.contains?(message, "recorded_by_not_authorized") ->
        {:error, :forbidden}

      String.contains?(message, "undefined_function") or
          String.contains?(message, "does not exist") ->
        {:error, :database_unavailable}

      true ->
        Logger.error("Direct contract database error: #{inspect(error)}")
        {:error, :database_unavailable}
    end
  end

  defp map_pg(error) do
    Logger.error("Direct contract database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end

  defp require_admin(user_id) when is_binary(user_id) do
    cond do
      Auth.admin?(user_id) ->
        :ok

      true ->
        case Repo.query(
               "SELECT role_id::text FROM public.user_roles WHERE user_id = $1::uuid AND (role_id = 'reviewer' OR role_id = ANY($2::text[]))",
               [Ecto.UUID.dump!(user_id), Mithril.OpsPermissions.ids()]
             ) do
          {:ok, %{rows: rows}} ->
            roles = Enum.map(rows, &hd/1)
            grants = Enum.filter(roles, &Mithril.OpsPermissions.valid?/1)

            if "contracts" in grants or (grants == [] and "reviewer" in roles),
              do: :ok,
              else: {:error, :forbidden}

          _ ->
            {:error, :forbidden}
        end
    end
  end

  defp require_admin(_), do: {:error, :forbidden}

  defp month_or_current(nil), do: {:ok, Calendar.period_start(Calendar.today())}
  defp month_or_current(""), do: month_or_current(nil)

  defp month_or_current(value) do
    case Calendar.parse_month(value) do
      {:ok, month} -> {:ok, month}
      :error -> {:error, :invalid_request}
    end
  end

  defp client_attrs(params) do
    with {:ok, name} <- required_text(param(params, "name"), 120),
         {:ok, kind} <- one_of(param(params, "kind"), ~w(company person)),
         {:ok, contact} <- optional_text(param(params, "billingContact"), 120),
         {:ok, phone} <- optional_phone(param(params, "phone")),
         {:ok, email} <- optional_email(param(params, "email")) do
      {:ok, %{name: name, kind: kind, billing_contact: contact, phone: phone, email: email}}
    end
  end

  defp assignment_attrs(params) do
    with {:ok, attrs} <- assignment_update_attrs(params),
         {:ok, worker} <- worker_target(params) do
      {:ok, Map.merge(attrs, worker)}
    end
  end

  defp worker_target(params) do
    worker_id = present(param(params, "workerId"))
    phone = present(param(params, "workerPhone"))

    cond do
      is_binary(worker_id) ->
        with {:ok, id} <- cast_uuid(worker_id) do
          {:ok, %{worker_id: id, worker_phone: nil, worker_name: nil}}
        end

      is_binary(phone) ->
        with {:ok, e164} <- required_phone(phone),
             {:ok, name} <- required_text(param(params, "workerName"), 120) do
          {:ok, %{worker_id: nil, worker_phone: e164, worker_name: name}}
        end

      true ->
        {:error, :invalid_request}
    end
  end

  defp insert_assignment(contract_uid, attrs) do
    case fetch!(
           "SELECT cl.name FROM public.direct_contracts c JOIN public.direct_contract_clients cl ON cl.id = c.client_id WHERE c.id = $1",
           [
             contract_uid
           ]
         ).rows do
      [] -> Repo.rollback(:contract_not_found)
      [[client_name]] -> insert_assignment(contract_uid, attrs, client_name)
    end
  end

  defp insert_assignment(contract_uid, attrs, client_name) do
    {worker_id, phone, name, created?} = resolve_worker(attrs)

    case dump_uuid(worker_id) do
      {:ok, worker_uid} ->
        unless created? do
          case fetch!("SELECT 1 FROM public.cleaner_data WHERE user_id = $1", [worker_uid]).rows do
            [] -> Repo.rollback(:worker_not_found)
            _ -> :ok
          end
        end

        %{rows: [[id]]} =
          fetch!(
            """
            INSERT INTO public.direct_contract_assignments (
              contract_id, worker_id, role_label, monthly_pay_minor, client_rate_minor,
              weekly_advance_minor, advance_weekday, advance_mode
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING id::text
            """,
            [
              contract_uid,
              worker_uid,
              attrs.role,
              attrs.pay,
              attrs.rate,
              attrs.amount,
              attrs.weekday,
              attrs.mode
            ]
          )

        notice =
          if is_binary(phone) do
            %{phone: phone, name: name, role: attrs.role, client: client_name}
          end

        %{assignment: %{"id" => id}, notice: notice}

      :error ->
        Repo.rollback(:invalid_request)
    end
  end

  defp resolve_worker(%{worker_id: worker_id}) when is_binary(worker_id) do
    {worker_id, nil, nil, false}
  end

  defp resolve_worker(%{worker_phone: phone, worker_name: name}) do
    fetch!("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", ["contract-worker:#{phone}"])

    case find_worker_by_phone(phone) do
      {worker_id, worker_uid} ->
        ensure_cleaner_row(worker_uid)
        ensure_cleaner_role(worker_uid)
        {worker_id, phone, profile_name(worker_uid, name), true}

      nil ->
        {worker_id, worker_uid} = create_worker(phone, name)
        {worker_id, phone, profile_name(worker_uid, name), true}
    end
  end

  defp find_worker_by_phone(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    local =
      if String.starts_with?(digits, "233"),
        do: "0" <> String.slice(digits, 3..-1//1),
        else: digits

    case fetch!(
           """
           SELECT id::text
           FROM public.users
           WHERE phone = $1
              OR regexp_replace(COALESCE(phone, ''), '\\D', '', 'g') = ANY($2::text[])
           ORDER BY CASE WHEN phone = $1 THEN 0 ELSE 1 END
           LIMIT 1
           """,
           [phone, Enum.uniq([digits, local])]
         ).rows do
      [[id]] -> {id, Ecto.UUID.dump!(id)}
      [] -> nil
    end
  end

  defp create_worker(phone, name) do
    worker_id =
      if login_tables?() do
        case Auth.ensure_phone_account(phone) do
          {:ok, %{user_id: id}} ->
            id

          {:error, :phone_taken} ->
            case find_worker_by_phone(phone) do
              {id, _} -> id
              nil -> Repo.rollback(:phone_taken)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      else
        id = Ecto.UUID.generate()
        insert_columns("users", user_fields(Ecto.UUID.dump!(id), phone))
        id
      end

    worker_uid = Ecto.UUID.dump!(worker_id)
    ensure_cleaner_row(worker_uid)
    ensure_profile(worker_uid, name)
    ensure_cleaner_role(worker_uid)
    {worker_id, worker_uid}
  end

  defp ensure_cleaner_row(worker_uid) do
    fetch!(
      """
      INSERT INTO public.cleaner_data (user_id)
      VALUES ($1)
      ON CONFLICT (user_id) DO NOTHING
      """,
      [worker_uid]
    )
  end

  defp ensure_profile(worker_uid, name) do
    {first, last} = split_name(name)

    case fetch!("SELECT 1 FROM public.profiles WHERE id = $1", [worker_uid]).rows do
      [] ->
        insert_columns("profiles", profile_fields(worker_uid, name, first, last))

      _ ->
        if "fullname" in table_columns("profiles") do
          fetch!(
            """
            UPDATE public.profiles
            SET fullname = $2
            WHERE id = $1 AND (fullname IS NULL OR btrim(fullname) = '')
            """,
            [worker_uid, name]
          )
        end
    end
  end

  defp ensure_cleaner_role(worker_uid) do
    if relation?("public.roles") and relation?("public.user_roles") do
      role_columns = table_columns("roles")

      role_insert =
        if "description" in role_columns do
          "INSERT INTO public.roles (id, description) SELECT 'cleaner', 'Cleaner'"
        else
          "INSERT INTO public.roles (id) SELECT 'cleaner'"
        end

      fetch!(
        role_insert <> " WHERE NOT EXISTS (SELECT 1 FROM public.roles WHERE id = 'cleaner')",
        []
      )

      fetch!(
        """
        INSERT INTO public.user_roles (user_id, role_id)
        SELECT $1, 'cleaner'
        WHERE NOT EXISTS (
          SELECT 1 FROM public.user_roles WHERE user_id = $1 AND role_id = 'cleaner'
        )
        """,
        [worker_uid]
      )
    end
  end

  defp profile_name(worker_uid, fallback) do
    if "fullname" in table_columns("profiles") do
      case fetch!(
             "SELECT NULLIF(btrim(fullname), '') FROM public.profiles WHERE id = $1",
             [worker_uid]
           ).rows do
        [[name]] when is_binary(name) -> name
        _ -> fallback
      end
    else
      fallback
    end
  end

  defp user_fields(uid, phone) do
    [
      {"id", uid},
      {"phone", phone},
      {"password_hash", ""},
      {"status", "active"},
      {"created_at", DateTime.utc_now()},
      {"updated_at", DateTime.utc_now()}
    ]
  end

  defp profile_fields(uid, name, first, last) do
    [
      {"id", uid},
      {"user_id", uid},
      {"fullname", name},
      {"firstname", first},
      {"lastname", last}
    ]
  end

  defp insert_columns(table, fields) do
    available = table_columns(table)
    pairs = Enum.filter(fields, fn {column, _} -> column in available end)
    columns = Enum.map(pairs, &elem(&1, 0))
    values = Enum.map(pairs, &elem(&1, 1))
    holders = Enum.map_join(1..length(values), ", ", &"$#{&1}")

    fetch!(
      "INSERT INTO public.#{table} (#{Enum.join(columns, ", ")}) VALUES (#{holders})",
      values
    )
  end

  defp table_columns(table) do
    fetch!(
      """
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1
      """,
      [table]
    ).rows
    |> Enum.map(&hd/1)
    |> MapSet.new()
  end

  defp login_tables? do
    relation?("auth.users") and relation?("public.mithril_auth_accounts") and
      relation?("public.mithril_auth_identities")
  end

  defp relation?(name) do
    fetch!("SELECT to_regclass($1) IS NOT NULL", [name]).rows == [[true]]
  end

  defp assignment_count(sql, params) do
    fetch!(sql, params).rows |> hd() |> hd() |> int()
  end

  defp assignment_with_notice(assignment, :skipped), do: Map.put(assignment, "notified", false)

  defp assignment_with_notice(assignment, :ok), do: Map.put(assignment, "notified", true)

  defp assignment_with_notice(assignment, {:error, :not_on_whatsapp}) do
    assignment
    |> Map.put("notified", false)
    |> Map.put("notificationError", "not_on_whatsapp")
  end

  defp assignment_with_notice(assignment, {:error, _}), do: Map.put(assignment, "notified", false)

  defp notify_added_worker(_user_id, nil), do: :skipped

  defp notify_added_worker(user_id, notice) do
    {:ok, admin_uid} = dump_uuid(user_id)

    case WorkerAddedTemplate.deliver(
           admin_uid,
           notice.phone,
           notice.name,
           notice.role,
           notice.client
         ) do
      :ok ->
        :ok

      {:error, :not_on_whatsapp} = error ->
        error

      {:error, reason} = error ->
        Logger.warning("contract worker WhatsApp was not delivered: #{inspect(reason)}")
        error
    end
  end

  def worker_added_message(name, role, client) do
    WorkerAddedTemplate.readable(name, role, client)
  end

  defp split_name(name) do
    case String.split(name, ~r/\s+/, parts: 2) do
      [first, last] -> {first, last}
      [first] -> {first, ""}
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp required_phone(value) do
    case optional_phone(value) do
      {:ok, nil} -> {:error, :invalid_phone}
      other -> other
    end
  end

  defp assignment_update_attrs(params) do
    with {:ok, role} <- required_text(param(params, "roleLabel"), 80),
         {:ok, pay} <- positive_int(param(params, "monthlyPayMinor")),
         {:ok, rate} <- non_negative_int(param(params, "clientRateMinor")),
         {:ok, schedule} <- advance_schedule(params) do
      {:ok, Map.merge(%{role: role, pay: pay, rate: rate}, schedule)}
    end
  end

  defp advance_schedule(params) do
    amount = param(params, "weeklyAdvanceMinor")
    mode = param(params, "advanceMode") || "manual"

    if blank?(amount) do
      {:ok, %{amount: nil, weekday: nil, mode: "manual"}}
    else
      with {:ok, parsed} <- positive_int(amount),
           {:ok, weekday} <- weekday_number(param(params, "advanceWeekday")),
           {:ok, parsed_mode} <- one_of(mode, ~w(manual automatic)) do
        {:ok, %{amount: parsed, weekday: weekday, mode: parsed_mode}}
      end
    end
  end

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, String.to_atom(key))
    end
  end

  defp optional_boolean(nil), do: {:ok, nil}
  defp optional_boolean(value) when value in [true, false], do: {:ok, value}
  defp optional_boolean("true"), do: {:ok, true}
  defp optional_boolean("false"), do: {:ok, false}
  defp optional_boolean(_), do: {:error, :invalid_request}

  defp required_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, :invalid_request}
      String.length(trimmed) > max -> {:error, :invalid_request}
      true -> {:ok, trimmed}
    end
  end

  defp required_text(_, _), do: {:error, :invalid_request}

  defp optional_date(nil), do: {:ok, nil}
  defp optional_date(""), do: {:ok, nil}

  defp optional_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_request}
    end
  end

  defp optional_date(%Date{} = date), do: {:ok, date}
  defp optional_date(_), do: {:error, :invalid_request}

  defp optional_text(nil, _), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > max -> {:error, :invalid_request}
      true -> {:ok, trimmed}
    end
  end

  defp optional_text(_, _), do: {:error, :invalid_request}

  defp optional_phone(nil), do: {:ok, nil}
  defp optional_phone(""), do: {:ok, nil}

  defp optional_phone(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      phone ->
        case ghana_phone(phone) do
          {:ok, e164} -> {:ok, e164}
          :error -> {:error, :invalid_phone}
        end
    end
  end

  defp optional_phone(_), do: {:error, :invalid_phone}

  defp ghana_phone(value) do
    with {:ok, parsed} <- ExPhoneNumber.parse(value, "GH"),
         true <- ExPhoneNumber.is_valid_number?(parsed),
         233 <- parsed.country_code do
      {:ok, ExPhoneNumber.format(parsed, :e164)}
    else
      _ -> :error
    end
  end

  defp optional_email(nil), do: {:ok, nil}

  defp optional_email(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      email ->
        case ExEmail.validate(email) do
          :ok -> {:ok, email}
          {:error, _} -> {:error, :invalid_email}
        end
    end
  end

  defp optional_email(_), do: {:error, :invalid_email}

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(""), do: {:ok, nil}
  defp optional_uuid(value), do: cast_uuid(value)

  defp optional_uuid_dump(nil), do: {:ok, nil}
  defp optional_uuid_dump(""), do: {:ok, nil}

  defp optional_uuid_dump(value) do
    case dump_uuid(value) do
      {:ok, dumped} -> {:ok, dumped}
      :error -> {:error, :invalid_request}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp cast_uuid(_), do: {:error, :invalid_request}

  defp dump_uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> {:ok, dumped}
      :error -> :error
    end
  end

  defp dump_uuid(_), do: :error

  defp uuid_text(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.load!(value)
    end
  end

  defp one_of(value, allowed) when is_binary(value) and is_list(allowed) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp one_of(_, _), do: {:error, :invalid_request}

  defp weekday_number(value) when is_integer(value) and value in 0..6, do: {:ok, value}

  defp weekday_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> weekday_number(parsed)
      _ -> {:error, :invalid_request}
    end
  end

  defp weekday_number(_), do: {:error, :invalid_request}

  defp positive_int(value), do: int_in(value, 1)

  defp non_negative_int(value), do: int_in(value, 0)

  defp int_in(value, minimum)
       when is_integer(value) and value >= minimum and value <= 2_147_483_647 do
    {:ok, value}
  end

  defp int_in(value, minimum) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> int_in(parsed, minimum)
      _ -> {:error, :invalid_amount}
    end
  end

  defp int_in(_, _), do: {:error, :invalid_amount}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp int(value) when is_integer(value), do: value
  defp int(%Decimal{} = value), do: Decimal.to_integer(value)
  defp int(nil), do: 0

  defp date_weekday(%Date{} = date) do
    case Date.day_of_week(date) do
      7 -> 0
      weekday -> weekday
    end
  end

  defp search_term(nil), do: {:ok, ""}

  defp search_term(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.replace(~r/[%_]/, "")
    if String.length(trimmed) > 80, do: {:error, :invalid_request}, else: {:ok, trimmed}
  end

  defp search_term(_), do: {:error, :invalid_request}

  defp like_pattern(""), do: "%"
  defp like_pattern(term), do: "%#{term}%"

  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp view_url(token) do
    base =
      Application.get_env(:mithril, :direct_public_url, "https://direct.tryinstaclean.com")
      |> to_string()
      |> String.trim_trailing("/")

    "#{base}/invoices/contract/#{token}"
  end

  defp resend_url,
    do: Application.get_env(:mithril, :resend_api_url, "https://api.resend.com/emails")

  defp resend_options(body, api_key) do
    options = [json: body, auth: {:bearer, api_key}]
    extra = Application.get_env(:mithril, :resend_req_options, [])
    if is_list(extra), do: Keyword.merge(options, extra), else: options
  end

  defp html_escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
