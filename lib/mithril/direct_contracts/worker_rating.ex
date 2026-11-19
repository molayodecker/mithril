defmodule Mithril.DirectContracts.WorkerRating do
  @moduledoc """
  Asks a contract client to rate the worker in their home.

  Staff can send the WhatsApp at any time, and can type a different number for
  that one message. A daily job sends the next request three months after the
  contract starts, then three months after each send.
  """

  require Logger

  alias Mithril.Repo
  alias Mithril.WhatsApp.ContractWorkerRatingTemplate

  @token ~r/^[0-9a-f]{64}$/

  def send(admin_id, contract_id, params, source)
      when is_map(params) and source in [:manual, :automatic] do
    with {:ok, admin_uid} <- dump_uuid(admin_id),
         {:ok, contract_uid} <- dump_uuid(contract_id),
         {:ok, override} <- override_phone(params),
         {:ok, contact} <- load_contact(contract_uid),
         {:ok, phone} <- choose_phone(override, contact.phone),
         {:ok, workers} <- load_workers(contract_uid, source),
         token <- new_token(),
         {:ok, request_id} <- persist(contract_uid, token, phone, workers, admin_uid, source) do
      case ContractWorkerRatingTemplate.deliver(
             admin_uid,
             phone,
             greeting(contact.name),
             worker_label(Enum.map(workers, &elem(&1, 1))),
             token
           ) do
        :ok ->
          {:ok, %{"ok" => true, "sent" => true, "phone" => phone}}

        {:error, reason} ->
          _ = delete_request(request_id)
          {:error, reason}
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_due(limit \\ 20) when is_integer(limit) and limit > 0 do
    case system_admin() do
      {:ok, admin_id} ->
        case due_contract_ids(limit) do
          {:ok, ids} ->
            Enum.each(ids, fn contract_id ->
              case send(admin_id, contract_id, %{}, :automatic) do
                {:ok, _} ->
                  :ok

                {:error, reason} ->
                  Logger.error(
                    "Contract worker rating was not sent for #{contract_id}: #{inspect(reason)}"
                  )
              end
            end)

            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :no_admin} ->
        Logger.error("Contract worker rating sweep has no admin sender")
        :ok
    end
  end

  def show(token) when is_binary(token) do
    if token_ok?(token), do: load_show(token), else: {:error, :not_found}
  end

  def show(_), do: {:error, :not_found}

  def submit(token, params) when is_binary(token) and is_map(params) do
    with true <- token_ok?(token),
         {:ok, ratings} <- parse_ratings(params["ratings"] || params[:ratings]),
         :ok <- save_ratings(token, ratings) do
      show(token)
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def submit(_, _), do: {:error, :invalid_request}

  @doc """
  A rating is due on `today` when the contract started at least three calendar
  months earlier and the last send, if any, was at least three calendar months earlier.
  """
  def due?(%Date{} = start_on, last_sent_at, %Date{} = today) do
    threshold = Date.shift(today, month: -3)
    Date.compare(start_on, threshold) != :gt and quiet?(last_sent_at, threshold)
  end

  def greeting(value) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/[\r\n\t{}]+/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case String.split(cleaned, " ", parts: 2) do
      [name | _] when name != "" -> String.slice(name, 0, 60)
      _ -> "there"
    end
  end

  def worker_label(names) when is_list(names) do
    case Enum.filter(names, &(is_binary(&1) and String.trim(&1) != "")) do
      [name] ->
        name
        |> String.replace(~r/[\r\n\t{}]+/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 40)
        |> empty_as("your worker")

      _ ->
        "your team"
    end
  end

  defp quiet?(nil, _threshold), do: true

  defp quiet?(%DateTime{} = sent, threshold) do
    Date.compare(DateTime.to_date(sent), threshold) != :gt
  end

  defp load_show(token) do
    case Repo.query(
           """
           SELECT COALESCE(NULLIF(btrim(cl.billing_contact), ''), NULLIF(btrim(cl.name), ''), 'there'),
                  w.worker_id::text,
                  w.worker_name,
                  w.rating,
                  w.comment,
                  w.rated_at IS NOT NULL
           FROM public.direct_contract_rating_requests r
           JOIN public.direct_contracts c ON c.id = r.contract_id
           JOIN public.direct_contract_clients cl ON cl.id = c.client_id
           JOIN public.direct_contract_rating_workers w ON w.request_id = r.id
           WHERE r.token = $1
           ORDER BY w.worker_name, w.worker_id
           """,
           [token]
         ) do
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:ok, %{rows: rows}} -> {:ok, payload(rows)}
      {:error, error} -> database_error(error)
    end
  end

  defp payload([[name | _] | _] = rows) do
    workers =
      Enum.map(rows, fn [_name, id, worker_name, rating, comment, _rated] ->
        %{
          "workerId" => id,
          "name" => worker_name,
          "rating" => rating,
          "comment" => comment
        }
      end)

    %{
      "clientName" => greeting(name),
      "complete" => Enum.all?(rows, fn row -> Enum.at(row, 5) end),
      "workers" => workers
    }
  end

  defp save_ratings(token, ratings) do
    case Repo.transaction(fn -> save_ratings!(token, ratings) end) do
      {:ok, :ok} -> :ok
      {:error, %Postgrex.Error{} = error} -> database_error(error)
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_ratings!(token, ratings) do
    case Repo.query(
           """
           SELECT r.id, w.worker_id::text, w.rated_at IS NOT NULL
           FROM public.direct_contract_rating_requests r
           JOIN public.direct_contract_rating_workers w ON w.request_id = r.id
           WHERE r.token = $1
           FOR UPDATE
           """,
           [token]
         ) do
      {:ok, %{rows: []}} ->
        Repo.rollback(:not_found)

      {:ok, %{rows: rows}} ->
        if Enum.any?(rows, fn [_id, _worker, rated] -> rated end),
          do: Repo.rollback(:already_rated)

        request_id = rows |> hd() |> hd()
        expected = MapSet.new(Enum.map(rows, fn [_id, worker_id, _rated] -> worker_id end))
        given = MapSet.new(Enum.map(ratings, & &1.worker_id))
        if expected != given, do: Repo.rollback(:invalid_request)

        Enum.each(ratings, fn rating ->
          case Repo.query(
                 """
                 UPDATE public.direct_contract_rating_workers
                 SET rating = $3, comment = $4, rated_at = now()
                 WHERE request_id = $1 AND worker_id = $2 AND rated_at IS NULL
                 """,
                 [request_id, dump_uuid!(rating.worker_id), rating.rating, rating.comment]
               ) do
            {:ok, %{num_rows: 1}} -> :ok
            _ -> Repo.rollback(:invalid_request)
          end
        end)

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp persist(contract_uid, token, phone, workers, admin_uid, source) do
    case Repo.transaction(fn ->
           case Repo.query(
                  """
                  INSERT INTO public.direct_contract_rating_requests
                    (contract_id, token, phone, source, sent_by)
                  VALUES ($1, $2, $3, $4, $5)
                  RETURNING id
                  """,
                  [contract_uid, token, phone, Atom.to_string(source), admin_uid]
                ) do
             {:ok, %{rows: [[request_id]]}} ->
               Enum.each(workers, fn {worker_id, name} ->
                 case Repo.query(
                        """
                        INSERT INTO public.direct_contract_rating_workers
                          (request_id, worker_id, worker_name)
                        VALUES ($1, $2, $3)
                        """,
                        [request_id, dump_uuid!(worker_id), name]
                      ) do
                   {:ok, %{num_rows: 1}} -> :ok
                   {:error, error} -> Repo.rollback(error)
                 end
               end)

               request_id

             {:error, error} ->
               Repo.rollback(error)
           end
         end) do
      {:ok, request_id} -> {:ok, request_id}
      {:error, error} -> database_error(error)
    end
  end

  defp delete_request(request_id) do
    case Repo.query("DELETE FROM public.direct_contract_rating_requests WHERE id = $1", [
           request_id
         ]) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("Could not remove an unsent worker rating: #{inspect(error)}")
    end
  end

  defp due_contract_ids(limit) do
    case Repo.query(
           """
           SELECT c.id::text
           FROM public.direct_contracts c
           JOIN public.direct_contract_clients cl ON cl.id = c.client_id
           WHERE c.status = 'active'
             AND NULLIF(btrim(cl.phone), '') IS NOT NULL
             AND COALESCE(c.start_on, (c.created_at AT TIME ZONE 'Africa/Accra')::date)
                 <= ((now() AT TIME ZONE 'Africa/Accra')::date - interval '3 months')::date
             AND EXISTS (
               SELECT 1 FROM public.direct_contract_assignments a
               WHERE a.contract_id = c.id AND a.status = 'active'
             )
             AND NOT EXISTS (
               SELECT 1 FROM public.direct_contract_rating_requests r
               WHERE r.contract_id = c.id
                 AND (r.sent_at AT TIME ZONE 'Africa/Accra')::date
                     > ((now() AT TIME ZONE 'Africa/Accra')::date - interval '3 months')::date
             )
           ORDER BY c.created_at
           LIMIT $1
           """,
           [limit]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp system_admin do
    case Repo.query("""
         SELECT user_id::text
         FROM public.user_roles
         WHERE role_id = 'admin'
         ORDER BY user_id
         LIMIT 1
         """) do
      {:ok, %{rows: [[admin_id]]}} when is_binary(admin_id) -> {:ok, admin_id}
      {:ok, _} -> {:error, :no_admin}
      {:error, error} -> database_error(error)
    end
  end

  defp load_contact(contract_uid) do
    case Repo.query(
           """
           SELECT COALESCE(NULLIF(btrim(cl.billing_contact), ''), NULLIF(btrim(cl.name), '')),
                  NULLIF(btrim(cl.phone), '')
           FROM public.direct_contracts c
           JOIN public.direct_contract_clients cl ON cl.id = c.client_id
           WHERE c.id = $1
           """,
           [contract_uid]
         ) do
      {:ok, %{rows: [[name, phone]]}} -> {:ok, %{name: name, phone: phone}}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp load_workers(contract_uid, :automatic) do
    case active_workers(contract_uid) do
      {:ok, []} -> {:error, :no_worker}
      other -> other
    end
  end

  defp load_workers(contract_uid, :manual) do
    case active_workers(contract_uid) do
      {:ok, []} -> latest_worker(contract_uid)
      other -> other
    end
  end

  defp active_workers(contract_uid) do
    query_workers(
      """
      SELECT a.worker_id::text, #{worker_name_sql()}
      FROM public.direct_contract_assignments a
      LEFT JOIN public.profiles p ON p.id = a.worker_id
      WHERE a.contract_id = $1 AND a.status = 'active'
      ORDER BY a.created_at, a.worker_id
      """,
      [contract_uid]
    )
  end

  defp latest_worker(contract_uid) do
    case query_workers(
           """
           SELECT a.worker_id::text, #{worker_name_sql()}
           FROM public.direct_contract_assignments a
           LEFT JOIN public.profiles p ON p.id = a.worker_id
           WHERE a.contract_id = $1
           ORDER BY a.created_at DESC, a.worker_id
           LIMIT 1
           """,
           [contract_uid]
         ) do
      {:ok, []} -> {:error, :no_worker}
      other -> other
    end
  end

  defp worker_name_sql do
    """
    COALESCE(
      NULLIF(btrim(p.fullname), ''),
      NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
      'your worker'
    )
    """
  end

  defp query_workers(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn
           [id, name] when is_binary(id) ->
             label =
               if is_binary(name) and String.trim(name) != "",
                 do: String.trim(name),
                 else: "your worker"

             {id, label}
         end)}

      {:error, error} ->
        database_error(error)
    end
  end

  defp override_phone(params) do
    case params["phone"] || params[:phone] do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      phone when is_binary(phone) -> ghana_phone(phone)
      _ -> {:error, :invalid_phone}
    end
  end

  defp choose_phone(phone, _stored) when is_binary(phone), do: {:ok, phone}
  defp choose_phone(nil, stored) when is_binary(stored), do: ghana_phone(stored)
  defp choose_phone(nil, _), do: {:error, :missing_phone}

  defp ghana_phone(value) when is_binary(value) do
    with {:ok, parsed} <- ExPhoneNumber.parse(value, "GH"),
         true <- ExPhoneNumber.is_valid_number?(parsed),
         233 <- parsed.country_code do
      {:ok, ExPhoneNumber.format(parsed, :e164)}
    else
      _ -> {:error, :invalid_phone}
    end
  end

  defp parse_ratings(list) when is_list(list) and list != [] and length(list) <= 20 do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case parse_rating(item) do
        {:ok, rating} -> {:cont, {:ok, [rating | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ratings} ->
        ratings = Enum.reverse(ratings)
        ids = Enum.map(ratings, & &1.worker_id)

        if length(ids) == length(Enum.uniq(ids)),
          do: {:ok, ratings},
          else: {:error, :invalid_request}

      other ->
        other
    end
  end

  defp parse_ratings(_), do: {:error, :invalid_request}

  defp parse_rating(%{"workerId" => worker_id, "rating" => rating} = item)
       when is_binary(worker_id) and is_integer(rating) and rating in 1..5 do
    with {:ok, _} <- Ecto.UUID.cast(worker_id),
         {:ok, comment} <- optional_comment(Map.get(item, "comment")) do
      {:ok, %{worker_id: worker_id, rating: rating, comment: comment}}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_rating(%{workerId: worker_id, rating: rating} = item) do
    parse_rating(%{
      "workerId" => worker_id,
      "rating" => rating,
      "comment" => Map.get(item, :comment)
    })
  end

  defp parse_rating(_), do: {:error, :invalid_rating}

  defp optional_comment(nil), do: {:ok, nil}

  defp optional_comment(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      comment ->
        if String.length(comment) <= 500, do: {:ok, comment}, else: {:error, :invalid_request}
    end
  end

  defp optional_comment(_), do: {:error, :invalid_request}

  defp new_token, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  defp token_ok?(token), do: Regex.match?(@token, token)

  defp dump_uuid(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> {:ok, dumped}
      :error -> :error
    end
  end

  defp dump_uuid(_), do: :error

  defp dump_uuid!(value) do
    {:ok, dumped} = dump_uuid(value)
    dumped
  end

  defp empty_as("", fallback), do: fallback
  defp empty_as(value, _fallback), do: value

  defp database_error(%Postgrex.Error{} = error) do
    Logger.error("Contract worker rating database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end

  defp database_error(reason) when is_atom(reason), do: {:error, reason}
  defp database_error(reason), do: {:error, reason}
end
