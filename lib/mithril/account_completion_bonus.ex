defmodule Mithril.AccountCompletionBonus do
  @moduledoc false

  require Logger

  alias Mithril.Auth
  alias Mithril.DirectAdminActor
  alias Mithril.DirectAdminWallets
  alias Mithril.Repo
  alias Mithril.WhatsApp.AccountCompletionTemplate

  @batch 20
  @bonus_minor 2_500
  @notes "Account completion bonus"

  def send_offers(user_id) when is_binary(user_id) do
    with {:ok, admin_id} <- Ecto.UUID.cast(user_id),
         true <- Auth.staff?(admin_id) do
      deliver_batch(user_id, admin_id)
    else
      _ -> {:error, :forbidden}
    end
  end

  def send_offers(_), do: {:error, :forbidden}

  def unoffered_drafts(limit) when is_integer(limit) and limit > 0 do
    case Repo.query(unoffered_sql(true), [limit]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &draft_row/1)}
      {:error, error} -> database_error(error)
    end
  end

  def credit_if_offered(admin_id, application_id)
      when is_binary(admin_id) and is_binary(application_id) do
    case DirectAdminActor.with_actor(admin_id, fn ->
           credit_locked(admin_id, application_id)
         end) do
      {:ok, :credited} -> :credited
      {:ok, :skipped} -> :skipped
      {:error, reason} -> failed(reason)
    end
  rescue
    error -> failed(error)
  end

  def credit_if_offered(_, _), do: :skipped

  defp deliver_batch(user_id, admin_id) do
    case Repo.query(unoffered_sql(true), [@batch]) do
      {:ok, %{rows: rows}} ->
        {offered, failed} =
          Enum.reduce(rows, {0, 0}, fn row, {sent, missed} ->
            draft = draft_row(row)

            case AccountCompletionTemplate.deliver(user_id, draft.phone, draft.name) do
              :ok ->
                case record_offer(draft, admin_id) do
                  :ok ->
                    {sent + 1, missed}

                  {:error, reason} ->
                    Logger.warning("account completion offer was not recorded: #{label(reason)}")
                    {sent, missed + 1}
                end

              {:error, reason} ->
                Logger.warning("account completion WhatsApp was not sent: #{label(reason)}")
                {sent, missed + 1}
            end
          end)

        case remaining_count() do
          {:ok, remaining} ->
            {:ok, %{"offered" => offered, "failed" => failed, "remaining" => remaining}}

          {:error, reason} ->
            database_error(reason)
        end

      {:error, error} ->
        database_error(error)
    end
  end

  defp record_offer(draft, admin_id) do
    case Repo.query(
           """
           INSERT INTO public.account_completion_offers (draft_id, user_id, phone, offered_by)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (phone) DO NOTHING
           """,
           [draft.id, draft.user_id, draft.phone, Ecto.UUID.dump!(admin_id)]
         ) do
      {:ok, _} -> :ok
      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp remaining_count do
    case Repo.query("SELECT count(*)::int FROM (#{unoffered_sql(false)}) offers", []) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> {:ok, count}
      {:ok, _} -> {:error, :database_unavailable}
      {:error, error} -> {:error, error}
    end
  end

  defp credit_locked(admin_id, application_id) do
    case Repo.query(
           """
           SELECT o.id, ca.user_id
           FROM public.cleaner_applications ca
           LEFT JOIN public.users u ON u.id = ca.user_id
           JOIN public.account_completion_offers o
             ON o.credited_at IS NULL
            AND (
              (ca.user_id IS NOT NULL AND o.user_id = ca.user_id)
              OR o.phone = public.account_completion_phone(u.phone)
              OR o.phone = public.account_completion_phone(ca.phone)
            )
           WHERE ca.id = $1::uuid
           ORDER BY o.offered_at
           LIMIT 1
           FOR UPDATE OF o
           """,
           [application_id]
         ) do
      {:ok, %{rows: []}} ->
        :skipped

      {:ok, %{rows: [[offer_id, worker_id]]}} when not is_nil(worker_id) ->
        credit_offer(admin_id, offer_id, uuid_text(worker_id))

      {:ok, _} ->
        :skipped

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp credit_offer(admin_id, offer_id, worker_id) do
    case DirectAdminWallets.credit(admin_id, worker_id, %{
           "amountMinor" => @bonus_minor,
           "notes" => @notes
         }) do
      {:ok, _} ->
        case Repo.query(
               """
               UPDATE public.account_completion_offers
               SET credited_at = now(), user_id = $2::uuid
               WHERE id = $1 AND credited_at IS NULL
               """,
               [offer_id, worker_id]
             ) do
          {:ok, %{num_rows: 1}} -> :credited
          {:ok, _} -> Repo.rollback(:already_credited)
          {:error, error} -> Repo.rollback(error)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp draft_row([id, user_id, name, phone]) do
    %{
      id: id,
      user_id: user_id,
      name: if(is_binary(name) and String.trim(name) != "", do: name, else: "there"),
      phone: phone
    }
  end

  defp unoffered_sql(limited?) do
    limit = if limited?, do: "LIMIT $1", else: ""

    """
    SELECT
      d.id,
      d.user_id,
      COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
        NULLIF(btrim(concat_ws(' ', d.payload->>'firstName', d.payload->>'lastName')), ''),
        'there'
      ) AS name,
      public.account_completion_phone(COALESCE(NULLIF(btrim(u.phone), ''), d.payload->>'phone')) AS phone
    FROM public.cleaner_application_drafts d
    LEFT JOIN public.users u ON u.id = d.user_id
    LEFT JOIN public.profiles p ON p.id = d.user_id
    WHERE public.account_completion_phone(COALESCE(NULLIF(btrim(u.phone), ''), d.payload->>'phone')) IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.cleaner_data cd
        WHERE cd.user_id = d.user_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.cleaner_applications ca
        WHERE lower(btrim(ca.status::text)) = 'approved'
          AND (
            ca.user_id = d.user_id
            OR (
              NULLIF(lower(btrim(ca.email)), '') IS NOT NULL
              AND lower(btrim(ca.email)) IN (
                lower(btrim(COALESCE(d.email, ''))),
                lower(btrim(COALESCE(u.email, '')))
              )
            )
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.account_completion_offers o
        WHERE o.phone = public.account_completion_phone(COALESCE(NULLIF(btrim(u.phone), ''), d.payload->>'phone'))
           OR (d.user_id IS NOT NULL AND o.user_id = d.user_id)
      )
    ORDER BY d.created_at ASC NULLS LAST, d.id ASC
    #{limit}
    """
  end

  defp failed(reason) do
    Logger.warning("account completion bonus was not credited: #{label(reason)}")
    :failed
  end

  defp label(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp label(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code),
    do: Atom.to_string(code)

  defp label(_), do: "error"

  defp uuid_text(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.load!(value)
    end
  end

  defp database_error(%Postgrex.Error{postgres: %{message: message}}) do
    Logger.error("account completion bonus database error: #{message}")
    {:error, :database_unavailable}
  end

  defp database_error(error) do
    Logger.error("account completion bonus database error: #{label(error)}")
    {:error, :database_unavailable}
  end
end
