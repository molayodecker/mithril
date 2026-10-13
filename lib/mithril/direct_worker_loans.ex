defmodule Mithril.DirectWorkerLoans do
  @moduledoc "Worker loan requests and admin review."

  require Logger

  alias Mithril.Auth
  alias Mithril.DirectAdminActor
  alias Mithril.Repo

  @pending "pending"

  def create_request(worker_id, params) when is_map(params) do
    with {:ok, worker_uid} <- dump_uuid(worker_id),
         {:ok, amount} <- positive_int(params["amountMinor"] || params[:amountMinor]),
         {:ok, reason} <- optional_text(params["reason"] || params[:reason], 500) do
      case DirectAdminActor.with_actor(worker_uid, fn ->
             case Repo.query(
                    """
                    SELECT public.create_worker_loan_request(
                      p_worker_id := $1::uuid,
                      p_amount_minor := $2::integer,
                      p_reason := $3::text
                    )
                    """,
                    [worker_uid, amount, reason]
                  ) do
               {:ok, %{rows: [[payload]]}} -> payload
               {:error, error} -> Repo.rollback(error)
             end
           end) do
        {:ok, payload} -> {:ok, present_request(payload)}
        {:error, error} -> map_rpc_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_worker_requests(worker_id) do
    with {:ok, worker_uid} <- dump_uuid(worker_id),
         :ok <- require_worker_self(worker_uid, worker_uid),
         :ok <- require_cleaner(worker_uid) do
      {:ok, Enum.map(fetch_requests(worker_id: worker_uid), &present_row/1)}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def worker_summary(worker_id) do
    with {:ok, worker_uid} <- dump_uuid(worker_id),
         :ok <- require_worker_self(worker_uid, worker_uid),
         :ok <- require_cleaner(worker_uid) do
      {:ok, fetch_account_summary(worker_uid)}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_admin_requests(user_id, status \\ @pending) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, status_filter} <- request_status_filter(status) do
      {:ok, Enum.map(fetch_requests(status: status_filter), &present_row/1)}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def show_admin_request(user_id, request_id) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, request_uid} <- dump_uuid(request_id) do
      case fetch_requests(id: request_uid) do
        [row] -> {:ok, present_row(row)}
        [] -> {:error, :request_not_found}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def review(user_id, request_id, params) when is_map(params) do
    with {:ok, admin_uid} <- dump_uuid(user_id),
         :ok <- require_admin(admin_uid),
         {:ok, request_uid} <- dump_uuid(request_id),
         {:ok, decision} <- decision(params["decision"] || params[:decision]),
         {:ok, notes} <- optional_text(params["reviewNotes"] || params[:reviewNotes], 500) do
      case DirectAdminActor.with_actor(admin_uid, fn ->
             case Repo.query(
                    """
                    SELECT public.review_worker_loan_request(
                      p_request_id := $1::uuid,
                      p_reviewer_id := $2::uuid,
                      p_decision := $3::text,
                      p_review_notes := $4::text
                    )
                    """,
                    [request_uid, admin_uid, decision, notes]
                  ) do
               {:ok, %{rows: [[payload]]}} -> payload
               {:error, error} -> Repo.rollback(error)
             end
           end) do
        {:ok, payload} -> {:ok, present_review(payload)}
        {:error, error} -> map_rpc_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_requests(opts) do
    {where, args} =
      cond do
        id = Keyword.get(opts, :id) ->
          {"WHERE r.id = $1::uuid", [id]}

        worker_id = Keyword.get(opts, :worker_id) ->
          {"WHERE r.worker_id = $1::uuid ORDER BY r.created_at DESC LIMIT 50", [worker_id]}

        true ->
          case Keyword.get(opts, :status) do
            nil -> {"ORDER BY r.created_at DESC LIMIT 100", []}
            status -> {"WHERE r.status = $1::text ORDER BY r.created_at DESC LIMIT 100", [status]}
          end
      end

    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT
          r.id,
          r.worker_id,
          COALESCE(u.email, u.phone, 'Worker') AS worker_label,
          r.amount_minor,
          r.reason,
          r.status,
          r.review_notes,
          r.reviewed_at,
          r.created_at,
          COALESCE(a.outstanding_minor, 0) AS outstanding_minor
        FROM public.worker_loan_requests r
        JOIN public.users u ON u.id = r.worker_id
        LEFT JOIN public.worker_loan_accounts a ON a.worker_id = r.worker_id
        #{where}
        """,
        args
      )

    rows
  end

  defp fetch_account_summary(worker_uid) do
    {:ok, %{rows: rows}} =
      Repo.query(
        """
        SELECT COALESCE(a.outstanding_minor, 0), COALESCE(a.currency, 'GHS')
        FROM public.cleaner_data cd
        LEFT JOIN public.worker_loan_accounts a ON a.worker_id = cd.user_id
        WHERE cd.user_id = $1::uuid
        """,
        [worker_uid]
      )

    case rows do
      [[outstanding, currency]] ->
        %{"outstandingMinor" => outstanding, "currency" => currency || "GHS"}

      [] ->
        {:error, :worker_not_found}
    end
  end

  defp present_row([
         id,
         worker_id,
         worker_label,
         amount,
         reason,
         status,
         review_notes,
         reviewed_at,
         created_at,
         outstanding
       ]) do
    %{
      "id" => uuid_string(id),
      "workerId" => uuid_string(worker_id),
      "workerLabel" => worker_label,
      "amountMinor" => amount,
      "reason" => reason,
      "status" => status,
      "reviewNotes" => review_notes,
      "reviewedAt" => datetime_to_iso8601(reviewed_at),
      "createdAt" => datetime_to_iso8601(created_at),
      "outstandingMinor" => outstanding
    }
  end

  defp present_request(payload) when is_map(payload) do
    %{
      "id" => uuid_string(payload["id"] || payload[:id]),
      "workerId" => uuid_string(payload["workerId"] || payload[:workerId]),
      "amountMinor" => payload["amountMinor"] || payload[:amountMinor],
      "reason" => payload["reason"] || payload[:reason],
      "status" => payload["status"] || payload[:status] || @pending
    }
  end

  defp present_review(payload) when is_map(payload) do
    base = present_request(payload)

    Map.merge(base, %{
      "newBalanceMinor" => payload["newBalanceMinor"] || payload[:newBalanceMinor],
      "outstandingMinor" => payload["outstandingMinor"] || payload[:outstandingMinor]
    })
  end

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp require_worker_self(actor_uid, worker_uid) do
    if actor_uid == worker_uid, do: :ok, else: {:error, :forbidden}
  end

  defp require_cleaner(worker_uid) do
    case Repo.query("SELECT 1 FROM public.cleaner_data WHERE user_id = $1::uuid LIMIT 1", [
           worker_uid
         ]) do
      {:ok, %{num_rows: 1}} -> :ok
      _ -> {:error, :worker_not_found}
    end
  end

  defp request_status_filter(nil), do: {:ok, @pending}
  defp request_status_filter(""), do: {:ok, @pending}
  defp request_status_filter("all"), do: {:ok, nil}

  defp request_status_filter(status)
       when status in ["pending", "approved", "rejected", "cancelled"],
       do: {:ok, status}

  defp request_status_filter(_), do: {:error, :invalid_request}

  defp decision("approve"), do: {:ok, "approve"}
  defp decision("reject"), do: {:ok, "reject"}
  defp decision(:approve), do: {:ok, "approve"}
  defp decision(:reject), do: {:ok, "reject"}
  defp decision(_), do: {:error, :invalid_decision}

  defp positive_int(value) when is_integer(value) and value > 0 and value <= 2_147_483_647,
    do: {:ok, value}

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> positive_int(parsed)
      _ -> {:error, :invalid_amount}
    end
  end

  defp positive_int(_), do: {:error, :invalid_amount}

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

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp uuid_string(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp datetime_to_iso8601(_), do: nil

  defp map_rpc_error(%Postgrex.Error{postgres: %{message: message}} = error)
       when is_binary(message) do
    cond do
      String.contains?(message, "worker_not_found") -> {:error, :worker_not_found}
      String.contains?(message, "pending_request_exists") -> {:error, :pending_request_exists}
      String.contains?(message, "invalid_amount") -> {:error, :invalid_amount}
      String.contains?(message, "actor_not_authorized") -> {:error, :forbidden}
      String.contains?(message, "reviewer_not_authorized") -> {:error, :forbidden}
      String.contains?(message, "request_not_found") -> {:error, :request_not_found}
      String.contains?(message, "request_not_pending") -> {:error, :request_not_pending}
      String.contains?(message, "invalid_decision") -> {:error, :invalid_decision}
      String.contains?(message, "wallet_not_found") -> {:error, :wallet_not_found}
      String.contains?(message, "unsupported_currency") -> {:error, :unsupported_currency}
      String.contains?(message, "amount_too_large") -> {:error, :amount_too_large}
      String.contains?(message, "undefined_function") -> {:error, :database_unavailable}
      true -> database_error(error)
    end
  end

  defp map_rpc_error(error), do: database_error(error)

  defp database_error(error) do
    Logger.error("Direct worker loan database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
