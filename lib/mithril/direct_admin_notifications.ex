defmodule Mithril.DirectAdminNotifications do
  @moduledoc "Staff app notifications: search recipients, send, and delivery history."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo
  alias Mithril.Workers.AdminNotificationDelivery

  @types ~w(
    admin_message
    booking_confirmation
    booking_reminder
    booking_cancelled
    cleaner_assigned
    payment_received
    new_message
    booking_rescheduled
    review_request
  )

  @segments ~w(customers cleaners all_app_users)
  @broadcast_max 100
  @default_page_size 25

  def list_deliveries(user_id, params \\ %{}) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, paging} <- paging(params),
         {:ok, total} <- count_deliveries(),
         {:ok, rows} <- list_delivery_rows(paging) do
      {:ok,
       %{
         "deliveries" => rows,
         "page" => paging.page,
         "limit" => paging.limit,
         "total" => total,
         "totalPages" => total_pages(total, paging.limit)
       }}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def search_targets(user_id, query) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, search} <- validate_search(query) do
      case Repo.query(
             """
             SELECT jsonb_build_object(
               'id', u.id,
               'name', COALESCE(
                 NULLIF(btrim(p.fullname), ''),
                 NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
                 NULLIF(btrim(u.email), ''),
                 NULLIF(btrim(u.phone), ''),
                 'User'
               ),
               'email', u.email,
               'phone', u.phone
             )
             FROM public.users u
             LEFT JOIN public.profiles p ON p.id = u.id
             WHERE (
               u.email ILIKE '%' || $1 || '%'
               OR COALESCE(u.phone, '') ILIKE '%' || $1 || '%'
               OR COALESCE(p.fullname, '') ILIKE '%' || $1 || '%'
               OR COALESCE(p.firstname, '') ILIKE '%' || $1 || '%'
               OR COALESCE(p.lastname, '') ILIKE '%' || $1 || '%'
               OR u.id::text ILIKE '%' || $1 || '%'
             )
             ORDER BY COALESCE(p.fullname, u.email, u.phone, '') ASC
             LIMIT 25
             """,
             [search]
           ) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def send(user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, input} <- validate_send(params),
         {:ok, target_uid} <- dump_uuid(input.target_user_id),
         :ok <- insert_inbox(target_uid, input),
         {:ok, queued} <- enqueue_recipient_channels(user_id, input, input[:phone]) do
      {:ok,
       %{
         "ok" => true,
         "inboxCreated" => true,
         "smsSent" => queued.sms > 0,
         "whatsappSent" => queued.whatsapp > 0
       }}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  def preview_broadcast(user_id, params) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, segment} <- validate_segment(params["segment"] || params[:segment]),
         {:ok, {total, _with_phone}} <- count_audience(segment),
         {:ok, recipients} <- list_audience(segment, @broadcast_max) do
      selected = length(recipients)

      with_phone =
        Enum.count(recipients, fn recipient ->
          phone = recipient["phone"]
          is_binary(phone) and String.trim(phone) != ""
        end)

      {:ok,
       %{
         "segment" => segment,
         "segmentTotalCount" => total,
         "selectedForRun" => selected,
         "withPhoneCount" => with_phone,
         "capped" => total > @broadcast_max
       }}
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_broadcast(user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, input} <- validate_broadcast(params),
         {:ok, recipients} <- list_audience(input.segment, @broadcast_max),
         {:ok, inbox} <- insert_inbox_batch(recipients, input),
         {:ok, queued} <- enqueue_broadcast_channels(user_id, input, recipients) do
      {:ok,
       %{
         "ok" => true,
         "attempted" => length(recipients),
         "inboxCreated" => inbox,
         "smsSent" => queued.sms,
         "whatsappSent" => queued.whatsapp,
         "capped" => length(recipients) == @broadcast_max
       }}
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_deliveries do
    case Repo.query("SELECT COUNT(*)::int FROM public.notifications") do
      {:ok, %{rows: [[total]]}} when is_integer(total) -> {:ok, total}
      {:error, error} -> database_error(error)
    end
  end

  defp list_delivery_rows(paging) do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'id', n.id,
             'userId', n.user_id,
             'recipientName', COALESCE(
               NULLIF(btrim(p.fullname), ''),
               NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), ''),
               NULLIF(btrim(u.email), ''),
               NULLIF(btrim(u.phone), ''),
               'User'
             ),
             'recipientEmail', u.email,
             'recipientPhone', u.phone,
             'title', n.title,
             'message', n.message,
             'type', n.type::text,
             'read', COALESCE(n.read, false),
             'createdAt', n.created_at,
             'screen', NULLIF(n.data->>'screen', '')
           )
           FROM public.notifications n
           LEFT JOIN public.users u ON u.id = n.user_id
           LEFT JOIN public.profiles p ON p.id = n.user_id
           ORDER BY n.created_at DESC NULLS LAST
           LIMIT $1 OFFSET $2
           """,
           [paging.limit, paging.offset]
         ) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp count_audience(segment) do
    case Repo.query(
           """
           SELECT
             COUNT(DISTINCT u.id)::int,
             COUNT(DISTINCT u.id) FILTER (WHERE NULLIF(btrim(COALESCE(u.phone, '')), '') IS NOT NULL)::int
           FROM public.users u
           JOIN public.user_roles ur ON ur.user_id = u.id AND ur.role_id = ANY($1)
           """,
           [segment_roles(segment)]
         ) do
      {:ok, %{rows: [[total, with_phone]]}} -> {:ok, {total, with_phone}}
      {:error, error} -> database_error(error)
    end
  end

  defp list_audience(segment, limit) do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'id', u.id,
             'phone', u.phone
           )
           FROM public.users u
           JOIN public.user_roles ur ON ur.user_id = u.id AND ur.role_id = ANY($1)
           GROUP BY u.id, u.phone
           ORDER BY u.id
           LIMIT $2
           """,
           [segment_roles(segment), limit]
         ) do
      {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
      {:error, error} -> database_error(error)
    end
  end

  defp insert_inbox(target_uid, input) do
    data = inbox_data(input)

    case Repo.query(
           """
           INSERT INTO public.notifications (user_id, title, message, type, read, data)
           VALUES ($1, $2, $3, $4, false, $5::jsonb)
           """,
           [target_uid, input.title, input.message, input.type, data]
         ) do
      {:ok, _} -> :ok
      {:error, error} -> database_error(error)
    end
  end

  defp insert_inbox_batch(recipients, input) do
    ids =
      recipients
      |> Enum.map(&dump_uuid(&1["id"]))
      |> Enum.flat_map(fn
        {:ok, uid} -> [uid]
        _ -> []
      end)

    case ids do
      [] ->
        {:ok, 0}

      ids ->
        data = inbox_data(input)

        case Repo.query(
               """
               INSERT INTO public.notifications (user_id, title, message, type, read, data)
               SELECT x, $2, $3, $4, false, $5::jsonb
               FROM UNNEST($1::uuid[]) AS x
               """,
               [ids, input.title, input.message, input.type, data]
             ) do
          {:ok, %{num_rows: count}} -> {:ok, count}
          {:error, error} -> database_error(error)
        end
    end
  end

  defp inbox_data(%{screen: screen}) when is_binary(screen),
    do: Jason.encode!(%{"screen" => screen})

  defp inbox_data(_), do: "{}"

  defp enqueue_broadcast_channels(admin_user_id, input, recipients) do
    if input.include_sms or input.include_whatsapp do
      batch_id = Ecto.UUID.generate()

      jobs =
        Enum.flat_map(recipients, fn recipient ->
          channel_jobs(admin_user_id, batch_id, input, recipient["phone"])
        end)

      insert_jobs(jobs)
    else
      {:ok, %{sms: 0, whatsapp: 0}}
    end
  end

  defp enqueue_recipient_channels(admin_user_id, input, phone) do
    insert_jobs(channel_jobs(admin_user_id, Ecto.UUID.generate(), input, phone))
  end

  defp channel_jobs(_admin_user_id, _batch_id, input, _phone)
       when input.include_sms != true and input.include_whatsapp != true do
    []
  end

  defp channel_jobs(admin_user_id, batch_id, input, phone) do
    case present_phone(phone) || phone_for(input) do
      {:ok, e164} ->
        body = channel_body(input)
        from = Application.get_env(:mithril, :twilio_whatsapp_admin_from)

        []
        |> maybe_job(input.include_sms, fn ->
          AdminNotificationDelivery.new(%{
            "batch_id" => batch_id,
            "channel" => "sms",
            "phone" => e164,
            "body" => body
          })
        end)
        |> maybe_job(input.include_whatsapp, fn ->
          AdminNotificationDelivery.new(%{
            "batch_id" => batch_id,
            "channel" => "whatsapp",
            "admin_user_id" => admin_user_id,
            "phone" => e164,
            "body" => body,
            "from" => from
          })
        end)

      _ ->
        []
    end
  end

  defp maybe_job(jobs, true, builder), do: [builder.() | jobs]
  defp maybe_job(jobs, _, _), do: jobs

  defp insert_jobs(jobs) do
    case do_insert_jobs(jobs) do
      :ok ->
        {:ok,
         %{
           sms: Enum.count(jobs, &job_channel?(&1, "sms")),
           whatsapp: Enum.count(jobs, &job_channel?(&1, "whatsapp"))
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_insert_jobs([]), do: :ok

  defp do_insert_jobs(jobs) do
    inserter = Application.get_env(:mithril, :oban_insert, &default_insert_jobs/1)

    case inserter.(jobs) do
      :ok -> :ok
      {:ok, _} -> :ok
      list when is_list(list) -> :ok
      {:error, reason} -> {:error, reason}
      other when is_atom(other) -> {:error, other}
    end
  end

  defp default_insert_jobs(jobs) do
    if Application.get_env(:mithril, :start_oban, true) do
      Oban.insert_all(jobs)
    else
      Enum.each(jobs, &run_job_inline/1)
      :ok
    end
  end

  defp run_job_inline(%Ecto.Changeset{} = changeset) do
    args = Ecto.Changeset.get_field(changeset, :args) || Map.get(changeset.changes, :args, %{})
    AdminNotificationDelivery.perform(%Oban.Job{args: args})
  end

  defp job_channel?(%Ecto.Changeset{} = changeset, channel) do
    args = Ecto.Changeset.get_field(changeset, :args) || Map.get(changeset.changes, :args, %{})
    args["channel"] == channel
  end

  defp present_phone(phone) when is_binary(phone) do
    phone = String.trim(phone)
    if phone == "", do: nil, else: {:ok, phone}
  end

  defp present_phone(_), do: nil

  defp phone_for(input) do
    phone = input[:phone]

    if is_binary(phone) and String.trim(phone) != "" do
      {:ok, String.trim(phone)}
    else
      load_phone(input.target_user_id)
    end
  end

  defp channel_body(input), do: "#{input.title}\n\n#{input.message}"

  defp load_phone(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         {:ok, %{rows: [[phone]]}} when is_binary(phone) <-
           Repo.query("SELECT phone FROM public.users WHERE id = $1 LIMIT 1", [uid]),
         phone <- String.trim(phone),
         true <- phone != "" do
      {:ok, phone}
    else
      _ -> :error
    end
  end

  defp validate_send(params) do
    with {:ok, compose} <- validate_compose(params),
         target when is_binary(target) <- params["targetUserId"] || params[:targetUserId],
         target <- String.trim(target),
         true <- target != "" do
      {:ok, Map.put(compose, :target_user_id, target)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_broadcast(params) do
    with {:ok, compose} <- validate_compose(params),
         {:ok, segment} <- validate_segment(params["segment"] || params[:segment]) do
      {:ok, Map.put(compose, :segment, segment)}
    end
  end

  defp validate_compose(params) do
    title = params["title"] || params[:title]
    message = params["message"] || params[:message]
    type = params["type"] || params[:type] || "admin_message"
    screen = optional_text(params["screen"] || params[:screen], 120)
    include_sms = truthy?(params["includeSms"] || params[:includeSms])
    include_whatsapp = truthy?(params["includeWhatsapp"] || params[:includeWhatsapp])

    cond do
      not is_binary(title) or String.trim(title) == "" ->
        {:error, :invalid_request}

      not is_binary(message) or String.trim(message) == "" ->
        {:error, :invalid_request}

      type not in @types ->
        {:error, :invalid_request}

      true ->
        {:ok,
         %{
           title: String.trim(title) |> String.slice(0, 120),
           message: String.trim(message) |> String.slice(0, 2000),
           type: type,
           screen: screen,
           include_sms: include_sms,
           include_whatsapp: include_whatsapp
         }}
    end
  end

  defp validate_segment(segment) when segment in @segments, do: {:ok, segment}
  defp validate_segment(_), do: {:error, :invalid_request}

  defp segment_roles("customers"), do: ["customer"]
  defp segment_roles("cleaners"), do: ["cleaner"]
  defp segment_roles("all_app_users"), do: ["customer", "cleaner"]

  defp validate_search(query) do
    search =
      query
      |> to_string()
      |> String.trim()
      |> String.slice(0, 120)
      |> String.replace(~r/[%_]/, "")

    if String.length(search) < 2, do: {:error, :invalid_request}, else: {:ok, search}
  end

  defp paging(params) do
    with {:ok, limit} <- page_limit(params) do
      page = parse_positive_int(params["page"] || params[:page], 1)
      {:ok, %{page: page, limit: limit, offset: (page - 1) * limit}}
    end
  end

  defp page_limit(params) do
    {:ok, min(parse_positive_int(params["limit"] || params[:limit], @default_page_size), 100)}
  end

  defp parse_positive_int(raw, _default) when is_integer(raw) and raw > 0, do: raw

  defp parse_positive_int(raw, default) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

  defp total_pages(0, _), do: 1
  defp total_pages(total, limit), do: div(total + limit - 1, limit)

  defp optional_text(nil, _), do: nil
  defp optional_text("", _), do: nil

  defp optional_text(value, max) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: String.slice(value, 0, max)
  end

  defp optional_text(_, _), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(error) do
    Logger.error("Direct admin notifications database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
