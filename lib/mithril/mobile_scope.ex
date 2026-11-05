defmodule Mithril.MobileScope do
  @moduledoc """
  Authorization for mobile table access.

  Mithril's database role is not the Supabase `authenticated` role, and RLS is
  not the security boundary. Each query is scoped here to the caller from the
  JWT before SQL runs. Catalog reads stay open. Payment configuration and
  other people's rows are rejected.
  """

  @catalog MapSet.new(~w(
    app_feature_flags
    app_update_policy
    booking_settings
    extra_tasks
    micro_task_options
    micro_tasks
    platform_fees
    service_categories
    service_duration_options
    service_types
  ))

  @directory_select MapSet.new(~w(cleaner_data))

  @lifecycle MapSet.new(~w(
    bookings
    users
    jobs
    subscriptions
    transactions
    kyc_profiles
    cleaner_applications
    cleaner_data
    conversations
    conversation_list
    reviews
    job_offers
    booking_job_photos
    booking_micro_tasks
    co_cleaner_relationships
    co_cleaner_invitations
    preferred_cleaner_invitations
    auth_identity_lookup
    turnover_opportunities
  ))

  def mutation_predicate(table, index), do: clause(table, "update", index)

  def apply(user_id, action, table, where_sql, params) when is_binary(user_id) do
    apply(user_id, action, table, where_sql, params, [])
  end

  def apply(_user_id, _action, _table, _where_sql, _params), do: {:error, :forbidden}

  def apply(user_id, action, table, where_sql, params, opts)
      when is_binary(user_id) and is_list(opts) do
    case clause(table, action, length(params) + 1, opts) do
      :open ->
        {:ok, where_sql, params}

      {:error, reason} ->
        {:error, reason}

      {:ok, predicate} ->
        {:ok, append_predicate(where_sql, predicate), params ++ [user_id]}
    end
  end

  def apply(_user_id, _action, _table, _where_sql, _params, _opts), do: {:error, :forbidden}

  def prepare_rows(user_id, table, rows) when is_binary(user_id) and is_list(rows) do
    cond do
      MapSet.member?(@catalog, table) ->
        {:error, :forbidden}

      table == "cleaner_applications" ->
        {:ok, Enum.map(rows, &application_row(&1, user_id))}

      MapSet.member?(@lifecycle, table) ->
        {:error, :forbidden}

      force = force_column(table) ->
        {:ok,
         Enum.map(rows, fn row ->
           row = Map.put(row, force, user_id)
           row = if table == "profiles", do: Map.put(row, "user_id", user_id), else: row
           if table == "payout_methods", do: Map.put(row, "is_default", false), else: row
         end)}

      table == "properties" ->
        require_column(rows, "customer_id", user_id)

      table == "conversations" ->
        require_any(rows, ["customer_id", "cleaner_id"], user_id)

      table == "messages" ->
        {:ok, Enum.map(rows, &Map.put(&1, "sender_id", user_id))}

      table in [
        "booking_micro_tasks",
        "booking_job_photos",
        "job_photo_comparisons",
        "turnover_opportunities"
      ] ->
        {:ok, rows}

      table == "cleaner_tracking" ->
        {:ok, Enum.map(rows, &Map.put(&1, "cleaner_id", user_id))}

      table == "job_offers" ->
        require_column(rows, "cleaner_id", user_id)

      table == "reviews" ->
        require_column(rows, "reviewer_id", user_id)

      table in ["co_cleaner_relationships"] ->
        require_any(rows, ["lead_cleaner_id", "co_cleaner_id"], user_id)

      table in ["co_cleaner_invitations", "preferred_cleaner_invitations"] ->
        {:ok, Enum.map(rows, &Map.put(&1, "inviter_user_id", user_id))}

      true ->
        {:error, :forbidden}
    end
  end

  def prepare_rows(_user_id, _table, _rows), do: {:error, :forbidden}

  def insert_guard(table, index) do
    cond do
      table in ["messages"] ->
        {:ok,
         "AND (jsonb_populate_record(NULL::public.messages, value)).conversation_id IN (#{conversation_ids(index)})"}

      table == "cleaner_tracking" ->
        {:ok,
         "AND (jsonb_populate_record(NULL::public.cleaner_tracking, value)).booking_id IN (SELECT id FROM public.bookings WHERE cleaner_id::text = $#{index}::text)"}

      table in [
        "property_media",
        "property_preferred_cleaners",
        "property_private_instructions",
        "property_calendar_feeds"
      ] ->
        {:ok,
         "AND (jsonb_populate_record(NULL::public.#{table}, value)).property_id IN (#{property_ids(index)})"}

      table == "job_photo_comparisons" ->
        {:ok,
         "AND (jsonb_populate_record(NULL::public.job_photo_comparisons, value)).booking_id IN (#{assigned_active_booking_ids(index)})"}

      table == "cleaner_application_trainings" ->
        {:ok,
         "AND (jsonb_populate_record(NULL::public.cleaner_application_trainings, value)).application_id IN (#{pending_application_ids(index)})"}

      true ->
        :none
    end
  end

  defp clause(table, action, index, opts \\ []) do
    cond do
      MapSet.member?(@catalog, table) and action == "select" ->
        :open

      MapSet.member?(@catalog, table) ->
        {:error, :forbidden}

      MapSet.member?(@directory_select, table) and action == "select" ->
        :open

      # An applicant can edit only while review is pending. Keep this predicate in
      # the UPDATE itself so an admin approval racing with a save wins atomically.
      table == "cleaner_applications" and action == "update" ->
        {:ok,
         "cleaner_applications.user_id::text = $#{index}::text AND cleaner_applications.status::text = 'pending'"}

      table == "cleaner_applications" and action in ["insert", "upsert"] ->
        {:ok, "cleaner_applications.user_id::text = $#{index}::text"}

      table == "cleaner_application_trainings" and action in ["upsert", "delete"] ->
        {:ok,
         "cleaner_application_trainings.user_id::text = $#{index}::text AND cleaner_application_trainings.application_id IN (#{pending_application_ids(index)})"}

      MapSet.member?(@lifecycle, table) and action != "select" ->
        {:error, :forbidden}

      column = force_column(table) ->
        {:ok, "#{table}.#{column}::text = $#{index}::text"}

      table in ["bookings", "conversations", "conversation_list", "subscriptions"] ->
        {:ok, party_predicate(table, action, index, opts)}

      table == "jobs" and action == "select" ->
        {:ok,
         "#{party("jobs", ["customer_id", "claimed_by"], index)} OR (jobs.status = 'pending' AND jobs.claimed_by IS NULL AND jobs.id IN (SELECT job_id FROM public.job_offers WHERE cleaner_id::text = $#{index}::text))"}

      table == "jobs" ->
        {:ok, party("jobs", ["customer_id", "claimed_by"], index)}

      table == "transactions" ->
        {:ok, party("transactions", ["customer_id", "cleaner_id"], index)}

      table == "reviews" ->
        {:ok,
         "#{party("reviews", ["reviewer_id", "reviewee_id"], index)} OR reviews.booking_id IN (#{booking_ids(index)})"}

      table == "messages" ->
        {:ok, "messages.conversation_id IN (#{conversation_ids(index)})"}

      table == "job_photo_comparisons" and action == "select" ->
        {:ok, "job_photo_comparisons.booking_id IN (#{booking_ids(index)})"}

      table == "job_photo_comparisons" ->
        {:ok, "job_photo_comparisons.booking_id IN (#{assigned_active_booking_ids(index)})"}

      table in [
        "booking_micro_tasks",
        "booking_job_photos",
        "cleaner_tracking"
      ] ->
        {:ok, "#{table}.booking_id IN (#{booking_ids(index)})"}

      table == "job_offers" ->
        {:ok,
         "job_offers.cleaner_id::text = $#{index}::text OR job_offers.job_id IN (SELECT id FROM public.jobs WHERE customer_id::text = $#{index}::text)"}

      table == "turnover_opportunities" ->
        {:ok, "turnover_opportunities.property_id IN (#{property_ids(index)})"}

      table == "co_cleaner_invitations" ->
        {:ok, party(table, ["inviter_user_id", "accepted_user_id"], index)}

      table == "preferred_cleaner_invitations" ->
        {:ok, party(table, ["inviter_user_id", "accepted_cleaner_id"], index)}

      table == "co_cleaner_relationships" ->
        {:ok, party(table, ["lead_cleaner_id", "co_cleaner_id"], index)}

      true ->
        {:error, :forbidden}
    end
  end

  defp force_column("auth_identity_lookup"), do: "user_id"
  defp force_column("profiles"), do: "id"
  defp force_column("cleaner_data"), do: "user_id"
  defp force_column("cleaner_application_drafts"), do: "user_id"
  defp force_column("cleaner_applications"), do: "user_id"
  defp force_column("cleaner_application_trainings"), do: "user_id"
  defp force_column("device_tokens"), do: "user_id"
  defp force_column("kyc_profiles"), do: "user_id"
  defp force_column("notifications"), do: "user_id"
  defp force_column("payout_methods"), do: "user_id"
  defp force_column("preferred_cleaners"), do: "user_id"
  defp force_column("properties"), do: "customer_id"
  defp force_column("property_calendar_feeds"), do: "owner_id"
  defp force_column("property_media"), do: "owner_id"
  defp force_column("property_preferred_cleaners"), do: "owner_id"
  defp force_column("property_private_instructions"), do: "owner_id"
  defp force_column("user_profiles"), do: "user_id"
  defp force_column("users"), do: "id"
  defp force_column("cleaner_availability_exceptions"), do: "cleaner_id"
  defp force_column("cleaner_weekday_blocks"), do: "cleaner_id"
  defp force_column("availability"), do: "cleaner_id"
  defp force_column("cleaner_schedules"), do: "cleaner_id"
  defp force_column("cleaner_devices"), do: "cleaner_id"
  defp force_column(_), do: nil

  @application_server_columns ~w(
    id
    kyc_completed_at
    kyc_last_event_at
    kyc_provider
    kyc_provider_event
    kyc_review_answer
    kyc_review_status
    kyc_status
    ops_pending_review_reminder_sent_at
    sumsub_applicant_id
    sumsub_external_user_id
    sumsub_level_name
  )

  def application_row(row, user_id) when is_map(row) do
    row
    |> Map.drop(@application_server_columns)
    |> Map.put("user_id", user_id)
    |> Map.put("status", "pending")
    |> Map.put("admin_feedback", nil)
  end

  def application_patch(patch) when is_map(patch) do
    patch
    |> Map.drop(["user_id" | @application_server_columns])
    |> Map.drop(["status", "admin_feedback"])
  end

  defp party_predicate(table, action, index, opts) do
    owned = party(table, ["customer_id", "cleaner_id"], index)

    if table == "bookings" and action == "select" and opts[:include_broadcast_offers] do
      # Broadcast offers keep cleaner_id null. Id-list reads may also return rows
      # list_broadcast_assignments_for_cleaner would return for this caller.
      owned <>
        " OR bookings.id IN (SELECT public.list_broadcast_assignments_for_cleaner($#{index}::text::uuid))"
    else
      owned
    end
  end

  defp party(table, columns, index) do
    Enum.map_join(columns, " OR ", fn column ->
      "#{table}.#{column}::text = $#{index}::text"
    end)
  end

  # Lock the parent against concurrent approval while a training mutation runs.
  defp pending_application_ids(index) do
    "SELECT id FROM public.cleaner_applications WHERE user_id::text = $#{index}::text AND status::text = 'pending' FOR SHARE"
  end

  defp booking_ids(index) do
    "SELECT id FROM public.bookings WHERE customer_id::text = $#{index}::text OR cleaner_id::text = $#{index}::text"
  end

  defp assigned_active_booking_ids(index) do
    """
    SELECT id FROM public.bookings
    WHERE cleaner_id::text = $#{index}::text
      AND status::text NOT IN ('cancelled', 'completed')
    """
  end

  defp conversation_ids(index) do
    "SELECT id FROM public.conversations WHERE customer_id::text = $#{index}::text OR cleaner_id::text = $#{index}::text"
  end

  defp property_ids(index) do
    "SELECT id FROM public.properties WHERE customer_id::text = $#{index}::text"
  end

  defp append_predicate("", predicate), do: "WHERE " <> predicate

  defp append_predicate(where_sql, predicate), do: where_sql <> " AND (" <> predicate <> ")"

  defp require_column(rows, column, user_id) do
    if Enum.all?(rows, &(Map.get(&1, column) == user_id)) do
      {:ok, rows}
    else
      {:error, :forbidden}
    end
  end

  defp require_any(rows, columns, user_id) do
    if Enum.all?(rows, fn row -> Enum.any?(columns, &(Map.get(row, &1) == user_id)) end) do
      {:ok, rows}
    else
      {:error, :forbidden}
    end
  end
end
