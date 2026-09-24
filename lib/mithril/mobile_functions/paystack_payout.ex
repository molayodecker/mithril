defmodule Mithril.MobileFunctions.PaystackPayout do
  @moduledoc false

  alias Mithril.Auth.Phone
  alias Mithril.DbUuid
  alias Mithril.IdentityVerification
  alias Mithril.MobileFunctions.Paystack
  alias Mithril.MobileGateway
  alias Mithril.Repo

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @min_withdrawal_subunit 5_000
  @max_transfer_subunit 100_000_000

  @spec create_recipient(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_recipient(user_id, body) when is_binary(user_id) and is_map(body) do
    with {:ok, fields} <- parse_create_body(body),
         :ok <- ensure_paystack_configured(),
         {:ok, has_cleaner} <- user_has_cleaner_role?(user_id),
         :ok <- ensure_payout_role(fields.purpose, has_cleaner),
         {:ok, identity} <- resolve_identity(user_id),
         :ok <- ensure_identity_for_create(identity, fields.purpose),
         {:ok, existing} <- find_existing_recipient_code(user_id, fields),
         {:ok, result} <-
           maybe_reuse_or_create_paystack_recipient(user_id, fields, existing, identity) do
      {:ok, result}
    end
  end

  @spec initiate_transfer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def initiate_transfer(user_id, body) when is_binary(user_id) and is_map(body) do
    with {:ok, fields} <- parse_initiate_body(user_id, body),
         :ok <- ensure_paystack_configured(),
         {:ok, has_cleaner} <- user_has_cleaner_role?(user_id),
         :ok <- ensure_cleaner_can_withdraw(has_cleaner),
         :ok <- ensure_cleaner_active(user_id),
         {:ok, identity} <- resolve_identity(user_id),
         :ok <- ensure_identity_for_withdraw(identity),
         {:ok, payout_method} <- load_payout_method(user_id, fields.recipient),
         :ok <- ensure_payout_method_currency(payout_method, fields.currency),
         {:ok, wallet} <- wallet_balance(user_id),
         :ok <- ensure_wallet_currency(wallet, fields.currency),
         :ok <- ensure_sufficient_balance(wallet.balance, fields.amount),
         {:ok, existing} <- load_existing_payout(user_id, fields.reference),
         {:ok, result} <-
           continue_initiate(user_id, fields, payout_method, existing) do
      {:ok, result}
    end
  end

  defp parse_create_body(body) do
    type = Map.get(body, "type")
    name = body |> Map.get("name", "") |> to_string() |> String.trim()
    raw_account = body |> Map.get("account_number", "") |> to_string() |> String.trim()
    bank_code = body |> Map.get("bank_code", "") |> to_string() |> String.trim()
    currency = body |> Map.get("currency", "") |> to_string() |> String.trim() |> String.upcase()

    raw_purpose =
      body |> Map.get("purpose", "payout") |> to_string() |> String.trim() |> String.downcase()

    purpose = if raw_purpose == "refund", do: :refund, else: :payout

    cond do
      type not in ["nuban", "mobile_money"] ->
        {:error, {:status, 400, %{ok: false, error: "Invalid recipient type"}}}

      name == "" or String.length(name) > 200 ->
        {:error, {:status, 400, %{ok: false, error: "Invalid recipient name"}}}

      bank_code == "" ->
        message =
          if type == "nuban" do
            "Bank code is required for bank accounts"
          else
            "Bank code is required for mobile money recipients"
          end

        {:error, {:status, 400, %{ok: false, error: message}}}

      not Regex.match?(~r/^[A-Z0-9_-]{1,32}$/i, bank_code) ->
        {:error, {:status, 400, %{ok: false, error: "Invalid bank code"}}}

      currency not in ["GHS", "USD"] ->
        {:error, {:status, 400, %{ok: false, error: "Unsupported currency"}}}

      type == "mobile_money" and currency != "GHS" ->
        {:error, {:status, 400, %{ok: false, error: "Mobile money payout currency must be GHS"}}}

      true ->
        with {:ok, account_number} <- normalize_account_number(type, raw_account) do
          {:ok,
           %{
             type: type,
             name: name,
             account_number: account_number,
             bank_code: bank_code,
             currency: currency,
             purpose: purpose,
             payout_type: payout_method_type(type)
           }}
        end
    end
  end

  defp normalize_account_number("mobile_money", raw) do
    case format_ghana_mobile_money_for_paystack(raw) do
      nil ->
        {:error,
         {:status, 400,
          %{
            ok: false,
            error:
              "Invalid Ghana mobile money number. Use a valid Ghana mobile number like 0241234567 or +233241234567."
          }}}

      account_number ->
        {:ok, account_number}
    end
  end

  defp normalize_account_number("nuban", raw) do
    digits = raw |> String.replace(~r/\D/, "")

    if Regex.match?(~r/^\d{10,16}$/, digits) do
      {:ok, digits}
    else
      {:error, {:status, 400, %{ok: false, error: "Bank account number must be 10–16 digits"}}}
    end
  end

  defp parse_initiate_body(user_id, body) do
    amount_raw = Map.get(body, "amount")
    amount = if is_number(amount_raw), do: round(amount_raw), else: nil
    recipient = body |> Map.get("recipient", "") |> to_string() |> String.trim()

    reason =
      case Map.get(body, "reason") do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: nil, else: String.slice(trimmed, 0, 200)

        _ ->
          nil
      end

    currency =
      body |> Map.get("currency", "GHS") |> to_string() |> String.trim() |> String.upcase()

    reference_candidate =
      case Map.get(body, "reference") do
        value when is_binary(value) ->
          trimmed = String.trim(value)

          if trimmed == "" do
            generated_retry_reference(user_id, recipient, amount, currency)
          else
            trimmed
          end

        _ ->
          generated_retry_reference(user_id, recipient, amount, currency)
      end

    cond do
      currency not in ["GHS", "USD"] ->
        {:error, {:status, 400, %{ok: false, error: "Unsupported currency"}}}

      not is_integer(amount) or amount <= 0 ->
        {:error, {:status, 400, %{ok: false, error: "Invalid amount"}}}

      amount < @min_withdrawal_subunit ->
        {:error, {:status, 400, %{ok: false, error: "Minimum withdrawal is GHS 50.00"}}}

      amount > @max_transfer_subunit ->
        {:error, {:status, 400, %{ok: false, error: "Amount exceeds per-transfer limit"}}}

      not Regex.match?(@uuid_regex, reference_candidate) ->
        {:error, {:status, 400, %{ok: false, error: "Invalid withdrawal reference"}}}

      not Regex.match?(~r/^RCP_[A-Za-z0-9]+$/, recipient) ->
        {:error, {:status, 400, %{ok: false, error: "Invalid recipient code"}}}

      true ->
        {:ok,
         %{
           amount: amount,
           recipient: recipient,
           reason: reason,
           reference: reference_candidate,
           currency: currency
         }}
    end
  end

  defp generated_retry_reference(user_id, recipient, amount, currency) do
    bucket = System.system_time(:second) |> div(900)

    digest =
      :crypto.hash(
        :sha256,
        Enum.join(
          [user_id, recipient, to_string(amount), currency, Integer.to_string(bucket)],
          "|"
        )
      )
      |> Base.encode16(case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _::binary>> = digest

    Enum.join([a, b, c, d, e], "-")
  end

  defp ensure_paystack_configured do
    case Application.get_env(:mithril, :paystack_secret_key) do
      secret when is_binary(secret) and secret != "" -> :ok
      _ -> {:error, {:status, 500, %{ok: false, error: "Server misconfigured"}}}
    end
  end

  defp user_has_cleaner_role?(user_id) do
    sql = """
    SELECT 1
    FROM public.user_roles
    WHERE user_id = $1::uuid AND role_id = 'cleaner'
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(user_id)]) do
      {:ok, %{rows: [[1]]}} ->
        {:ok, true}

      {:ok, %{rows: _}} ->
        {:ok, false}

      {:error, error} ->
        {:error,
         {:status, 500,
          %{ok: false, error: db_error_message(error, "Could not verify cleaner role")}}}
    end
  end

  defp resolve_identity(user_id) do
    case IdentityVerification.resolve(user_id) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, _} ->
        {:error, {:status, 500, %{ok: false, error: "Could not verify identity status"}}}
    end
  end

  defp ensure_payout_role(:payout, false),
    do: {:error, {:status, 403, %{ok: false, error: "Only cleaners can add payout methods"}}}

  defp ensure_payout_role(_, _), do: :ok

  defp ensure_identity_for_create(%{verified: true}, _), do: :ok

  defp ensure_identity_for_create(_, :refund),
    do:
      {:error,
       {:status, 403,
        %{
          ok: false,
          error: "Only verified users can add refund accounts",
          code: "CLEANER_NOT_VERIFIED"
        }}}

  defp ensure_identity_for_create(_, :payout),
    do:
      {:error,
       {:status, 403,
        %{
          ok: false,
          error: "Only verified cleaners can add payout methods",
          code: "CLEANER_NOT_VERIFIED"
        }}}

  defp ensure_cleaner_can_withdraw(false),
    do: {:error, {:status, 403, %{ok: false, error: "Only cleaners can withdraw"}}}

  defp ensure_cleaner_can_withdraw(true), do: :ok

  defp ensure_cleaner_active(user_id) do
    sql = """
    SELECT status
    FROM public.cleaner_data
    WHERE user_id = $1::uuid
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(user_id)]) do
      {:ok, %{rows: [["active"]]}} ->
        :ok

      {:ok, %{rows: _}} ->
        {:error,
         {:status, 403,
          %{
            ok: false,
            error:
              "Your cleaner account is not active. Contact support if you believe this is an error."
          }}}

      {:error, error} ->
        {:error,
         {:status, 500,
          %{ok: false, error: db_error_message(error, "Could not verify cleaner status")}}}
    end
  end

  defp ensure_identity_for_withdraw(%{verified: true}), do: :ok

  defp ensure_identity_for_withdraw(_),
    do:
      {:error,
       {:status, 403,
        %{
          ok: false,
          error: "Only verified cleaners can withdraw",
          code: "CLEANER_NOT_VERIFIED"
        }}}

  defp ensure_sufficient_balance(balance, amount) when balance >= amount, do: :ok

  defp ensure_sufficient_balance(_, _),
    do: {:error, {:status, 400, %{ok: false, error: "Insufficient balance"}}}

  defp find_existing_recipient_code(user_id, fields) do
    sql = """
    SELECT recipient_code
    FROM public.payout_methods
    WHERE user_id = $1::uuid
      AND type = $2
      AND account_number = $3
      AND bank_code = $4
      AND purpose = $5
      AND upper(coalesce(currency, 'GHS')) = $6
    LIMIT 1
    """

    case Repo.query(sql, [
           DbUuid.dump!(user_id),
           fields.payout_type,
           fields.account_number,
           fields.bank_code,
           Atom.to_string(fields.purpose),
           fields.currency
         ]) do
      {:ok, %{rows: [[code]]}} when is_binary(code) ->
        {:ok, code}

      {:ok, %{rows: _}} ->
        {:ok, nil}

      {:error, error} ->
        {:error,
         {:status, 500,
          %{ok: false, error: db_error_message(error, "Could not verify existing payout methods")}}}
    end
  end

  defp maybe_reuse_or_create_paystack_recipient(user_id, fields, existing_code, _identity)
       when is_binary(existing_code) do
    write_recipient_audit(user_id, existing_code, fields)

    {:ok,
     %{
       ok: true,
       data: %{
         recipient_code: existing_code,
         reused: true
       }
     }}
  end

  defp maybe_reuse_or_create_paystack_recipient(user_id, fields, nil, _identity) do
    paystack_body = %{
      "type" => fields.type,
      "name" => fields.name,
      "account_number" => fields.account_number,
      "currency" => fields.currency,
      "bank_code" => fields.bank_code
    }

    with {:ok, secret} <- Paystack.secret_key(),
         {:ok, data} <- Paystack.post_json("/transferrecipient", paystack_body, secret) do
      recipient_code = Map.get(data, "recipient_code")
      write_recipient_audit(user_id, recipient_code, fields)
      {:ok, %{ok: true, data: data}}
    else
      {:error, :payment_not_configured} ->
        {:error, {:status, 500, %{ok: false, error: "Server misconfigured"}}}

      {:error, {:status, status, message}} ->
        http_status = if status >= 500, do: 502, else: 400
        {:error, {:status, http_status, %{ok: false, error: message}}}
    end
  end

  defp load_payout_method(user_id, recipient) do
    sql = """
    SELECT id, recipient_code, upper(coalesce(currency, 'GHS'))
    FROM public.payout_methods
    WHERE user_id = $1::uuid AND recipient_code = $2
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(user_id), recipient]) do
      {:ok, %{rows: [[id, code, currency]]}} ->
        {:ok, %{id: id, recipient_code: code, currency: currency}}

      {:ok, %{rows: _}} ->
        {:error, {:status, 404, %{ok: false, error: "Payout method not found"}}}

      {:error, error} ->
        {:error,
         {:status, 500,
          %{ok: false, error: db_error_message(error, "Could not verify payout method")}}}
    end
  end

  defp ensure_payout_method_currency(%{currency: currency}, requested_currency)
       when currency == requested_currency,
       do: :ok

  defp ensure_payout_method_currency(_payout_method, _requested_currency),
    do:
      {:error,
       {:status, 400, %{ok: false, error: "Payout method currency does not match withdrawal"}}}

  defp wallet_balance(user_id) do
    case MobileGateway.call_rpc(user_id, "get_my_wallet_balance", %{}) do
      {:ok, rows} when is_list(rows) ->
        case rows do
          [%{"balance" => value, "currency" => currency} | _]
          when is_number(value) and is_binary(currency) ->
            {:ok, %{balance: trunc(value), currency: String.upcase(String.trim(currency))}}

          [%{balance: value, currency: currency} | _]
          when is_number(value) and is_binary(currency) ->
            {:ok, %{balance: trunc(value), currency: String.upcase(String.trim(currency))}}

          [[value, currency] | _] when is_number(value) and is_binary(currency) ->
            {:ok, %{balance: trunc(value), currency: String.upcase(String.trim(currency))}}

          _ ->
            {:error, {:status, 500, %{ok: false, error: "Wallet currency is unavailable"}}}
        end

      {:error, _} ->
        {:error, {:status, 500, %{ok: false, error: "Could not read wallet balance"}}}
    end
  end

  defp ensure_wallet_currency(%{currency: currency}, requested_currency)
       when currency == requested_currency,
       do: :ok

  defp ensure_wallet_currency(_wallet, _requested_currency),
    do:
      {:error,
       {:status, 400, %{ok: false, error: "Withdrawal currency must match your wallet currency"}}}

  defp load_existing_payout(user_id, reference) do
    sql = """
    SELECT status, paystack_transfer_code, paystack_transfer_id, error_message
    FROM public.cleaner_payouts
    WHERE user_id = $1::uuid AND reference = $2::uuid
    LIMIT 1
    """

    case Repo.query(sql, [DbUuid.dump!(user_id), DbUuid.dump!(reference)]) do
      {:ok, %{rows: [[status, transfer_code, transfer_id, error_message]]}} ->
        {:ok,
         %{
           status: status,
           paystack_transfer_code: transfer_code,
           paystack_transfer_id: transfer_id,
           error_message: error_message
         }}

      {:ok, %{rows: _}} ->
        {:ok, nil}

      {:error, error} ->
        {:error,
         {:status, 500,
          %{ok: false, error: db_error_message(error, "Could not verify payout state")}}}
    end
  end

  defp continue_initiate(_user_id, _fields, _payout_method, %{status: "failed"} = existing) do
    {:error,
     {:status, 409,
      %{
        ok: false,
        error: existing.error_message || "Earlier transfer attempt failed"
      }}}
  end

  defp continue_initiate(_user_id, fields, _payout_method, existing) when not is_nil(existing) do
    {:ok, %{ok: true, data: reused_payout_data(fields, existing)}}
  end

  defp continue_initiate(user_id, fields, payout_method, nil) do
    with :ok <- begin_withdrawal(user_id, fields, payout_method),
         :ok <- insert_cleaner_payout(user_id, fields) do
      case call_paystack_transfer(fields) do
        {:ok, data} ->
          case persist_transfer_result(user_id, fields, data) do
            :ok ->
              {:ok, %{ok: true, data: data}}

            {:error, _} ->
              {:error,
               {:status, 502,
                %{
                  ok: false,
                  error: "Transfer was submitted but its local status could not be saved"
                }}}
          end

        {:error, {:status, status, body}} ->
          {:error, {:status, status, body}}
      end
    else
      {:error, {:race_conflict, raced}} ->
        handle_race(fields, raced)

      {:error, {:status, status, body}} ->
        {:error, {:status, status, body}}
    end
  end

  defp begin_withdrawal(user_id, fields, payout_method) do
    sql = """
    SELECT public.fn_begin_cleaner_withdrawal($1::uuid, $2::int, $3::uuid, $4::text, $5::uuid)
    """

    case Repo.query(sql, [
           DbUuid.dump!(user_id),
           fields.amount,
           DbUuid.dump!(fields.reference),
           fields.recipient,
           DbUuid.dump!(payout_method.id)
         ]) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{message: message}} when is_binary(message) ->
        map_begin_withdrawal_error(message)

      {:error, error} ->
        {:error,
         {:status, 500,
          %{ok: false, error: db_error_message(error, "Could not start withdrawal")}}}
    end
  end

  defp map_begin_withdrawal_error(message) do
    cond do
      String.contains?(message, "below_minimum_withdrawal") ->
        {:error, {:status, 400, %{ok: false, error: "Minimum withdrawal is GHS 50.00"}}}

      String.contains?(message, "insufficient_balance") ->
        {:error, {:status, 400, %{ok: false, error: "Insufficient balance"}}}

      String.contains?(message, "wallet_not_found") ->
        {:error,
         {:status, 400, %{ok: false, error: "No wallet found. Complete a paid job first."}}}

      String.contains?(message, "withdrawal_id_conflict") ->
        {:error, {:status, 400, %{ok: false, error: "Invalid withdrawal reference"}}}

      true ->
        {:error, {:status, 500, %{ok: false, error: "Could not start withdrawal"}}}
    end
  end

  defp insert_cleaner_payout(user_id, fields) do
    metadata = Jason.encode!(%{initiated_at: DateTime.utc_now() |> DateTime.to_iso8601()})

    sql = """
    INSERT INTO public.cleaner_payouts (
      user_id, recipient_code, amount, currency, reference, reason, status, metadata
    ) VALUES ($1::uuid, $2::text, $3::int, $4::text, $5::uuid, $6::text, 'pending', $7::jsonb)
    """

    case Repo.query(sql, [
           DbUuid.dump!(user_id),
           fields.recipient,
           fields.amount,
           fields.currency,
           DbUuid.dump!(fields.reference),
           fields.reason,
           metadata
         ]) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        case load_existing_payout(user_id, fields.reference) do
          {:ok, nil} ->
            {:error,
             {:status, 409,
              %{ok: false, error: "Transfer already in progress for this reference"}}}

          {:ok, raced} ->
            {:error, {:race_conflict, raced}}

          error ->
            error
        end

      {:error, error} ->
        message = db_error_message(error, "Could not reserve payout")
        fail_withdrawal(fields.reference, message)
        {:error, {:status, 500, %{ok: false, error: "Could not reserve payout"}}}
    end
  end

  defp handle_race(_fields, %{status: "failed"} = raced) do
    {:error,
     {:status, 409, %{ok: false, error: raced.error_message || "Earlier transfer attempt failed"}}}
  end

  defp handle_race(fields, raced) do
    {:ok, %{ok: true, data: reused_payout_data(fields, raced)}}
  end

  defp call_paystack_transfer(fields) do
    body =
      %{
        "source" => "balance",
        "amount" => fields.amount,
        "recipient" => fields.recipient,
        "currency" => fields.currency,
        "reference" => fields.reference
      }
      |> maybe_put_reason(fields.reason)

    with {:ok, secret} <- Paystack.secret_key(),
         {:ok, data} <- Paystack.post_json("/transfer", body, secret) do
      status = Map.get(data, "status", "pending")

      if status == "failed" do
        message =
          Map.get(data, "reason") || Map.get(data, "message") || "Paystack transfer failed"

        fail_withdrawal(fields.reference, message)
        {:error, {:status, 400, %{ok: false, error: message}}}
      else
        {:ok, data}
      end
    else
      {:error, :payment_not_configured} ->
        _ = fail_withdrawal(fields.reference, "Payment is not configured")
        {:error, {:status, 500, %{ok: false, error: "Server misconfigured"}}}

      {:error, {:status, status, message}} when status >= 500 ->
        _ = mark_withdrawal_processing(fields.reference, message)

        {:error,
         {:status, 502,
          %{
            ok: false,
            error: "Transfer status is unknown. Do not retry with a new reference.",
            code: "TRANSFER_STATUS_UNKNOWN"
          }}}

      {:error, {:status, _status, message}} ->
        _ = fail_withdrawal(fields.reference, message)
        {:error, {:status, 400, %{ok: false, error: message}}}
    end
  end

  defp persist_transfer_result(user_id, fields, data) do
    transfer_code = Map.get(data, "transfer_code")
    transfer_id = Map.get(data, "id")
    paystack_status = data |> Map.get("status", "pending") |> to_string() |> String.downcase()
    our_status = if paystack_status == "success", do: "success", else: "processing"

    with :ok <- maybe_finalize_immediate_success(fields.reference, our_status, transfer_code),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             UPDATE public.cleaner_payouts
             SET status = $3::public.withdrawal_status,
                 paystack_transfer_code = COALESCE($4::text, paystack_transfer_code),
                 paystack_transfer_id = COALESCE($5::bigint, paystack_transfer_id),
                 error_message = NULL,
                 updated_at = NOW()
             WHERE user_id = $1::uuid AND reference = $2::uuid
             """,
             [
               DbUuid.dump!(user_id),
               DbUuid.dump!(fields.reference),
               our_status,
               transfer_code,
               transfer_id
             ]
           ) do
      :ok
    else
      _ -> {:error, :payout_status_persist_failed}
    end
  end

  defp maybe_finalize_immediate_success(_reference, "processing", _transfer_code), do: :ok

  defp maybe_finalize_immediate_success(reference, "success", transfer_code) do
    case Repo.query(
           """
           SELECT public.fn_finalize_withdrawal(
             $1::text,
             'success'::public.withdrawal_status,
             NULL::text,
             $2::text
           )
           """,
           [reference, transfer_code]
         ) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :finalize_failed}
    end
  end

  defp mark_withdrawal_processing(reference, message) do
    case Repo.query(
           """
           UPDATE public.cleaner_payouts
           SET status = 'processing',
               error_message = $2::text,
               updated_at = NOW()
           WHERE reference = $1::uuid
             AND status IN ('pending', 'processing')
           """,
           [DbUuid.dump!(reference), message]
         ) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :payout_status_persist_failed}
    end
  end

  defp fail_withdrawal(reference, message) do
    case Repo.query(
           "SELECT public.fn_finalize_withdrawal($1::text, 'failed'::public.withdrawal_status, $2::text, NULL::text)",
           [reference, message]
         ) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, :finalize_failed}
    end
  end

  defp reused_payout_data(fields, payout) do
    %{
      "transfer_code" => payout.paystack_transfer_code,
      "id" => payout.paystack_transfer_id,
      "amount" => fields.amount,
      "currency" => fields.currency,
      "recipient" => fields.recipient,
      "reference" => fields.reference,
      "status" => payout.status,
      "reason" => fields.reason || "",
      "source" => "balance",
      "domain" => "reused"
    }
  end

  defp write_recipient_audit(user_id, recipient_code, fields) do
    masked = mask_account_tail(fields.account_number)

    sql = """
    INSERT INTO public.payout_recipient_audit (
      user_id, recipient_code, recipient_type, currency, masked_account, bank_code
    ) VALUES ($1::uuid, $2::text, $3::text, $4::text, $5::text, $6::text)
    """

    case Repo.query(sql, [
           DbUuid.dump!(user_id),
           recipient_code,
           fields.type,
           fields.currency,
           masked,
           fields.bank_code
         ]) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp mask_account_tail(account_number) do
    tail = account_number |> String.replace(~r/\D/, "") |> String.slice(-4, 4)
    if tail == "", do: "••••", else: "•••• #{tail}"
  end

  defp payout_method_type("mobile_money"), do: "mobile_money"
  defp payout_method_type(_), do: "bank"

  defp format_ghana_mobile_money_for_paystack(raw) do
    case Phone.normalize(raw) do
      {:ok, "+233" <> nine} when byte_size(nine) == 9 ->
        if Regex.match?(~r/^[2-5]\d{8}$/, nine), do: "0#{nine}", else: nil

      _ ->
        nil
    end
  end

  defp maybe_put_reason(body, nil), do: body
  defp maybe_put_reason(body, reason), do: Map.put(body, "reason", reason)

  defp db_error_message(%Postgrex.Error{message: message}, fallback) when is_binary(message),
    do: fallback

  defp db_error_message(_, fallback), do: fallback
end
