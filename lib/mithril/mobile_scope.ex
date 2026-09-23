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
    service_duration_options
    service_types
  ))

  @directory_select MapSet.new(~w(cleaner_data))

  def mutation_predicate(table, index), do: clause(table, "update", index)

  def apply(user_id, action, table, where_sql, params) when is_binary(user_id) do
    case clause(table, action, length(params) + 1) do
      :open ->
        {:ok, where_sql, params}

      {:error, reason} ->
        {:error, reason}

      {:ok, predicate} ->
        {:ok, append_predicate(where_sql, predicate), params ++ [user_id]}
    end
  end

  def apply(_user_id, _action, _table, _where_sql, _params), do: {:error, :forbidden}

  def prepare_rows(user_id, table, rows) when is_binary(user_id) and is_list(rows) do
    cond do
      MapSet.member?(@catalog, table) ->
        {:error, :forbidden}

      table in ["users", "bookings"] ->
        {:error, :forbidden}

      force = force_column(table) ->
        {:ok, Enum.map(rows, &Map.put(&1, force, user_id))}

      table in ["jobs", "subscriptions", "properties"] ->
        require_column(rows, "customer_id", user_id)

      table == "conversations" ->
        require_any(rows, ["customer_id", "cleaner_id"], user_id)

      table == "messages" ->
        require_column(rows, "sender_id", user_id)

      table in ["booking_micro_tasks", "booking_job_photos", "job_photo_comparisons", "cleaner_tracking", "turnover_opportunities"] ->
        {:ok, rows}

      table == "job_offers" ->
        require_column(rows, "cleaner_id", user_id)

      table == "transactions" ->
        require_any(rows, ["customer_id", "cleaner_id"], user_id)

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

      table in ["booking_micro_tasks", "booking_job_photos", "job_photo_comparisons", "cleaner_tracking"] ->
        column = if table == "cleaner_tracking", do: "booking_id", else: "booking_id"

        {:ok,
         "AND (jsonb_populate_record(NULL::public.#{table}, value)).#{column} IN (#{booking_ids(index)})"}

      table == "turnover_opportunities" ->
        {:ok,
         "AND (jsonb_populate_record(NULL::public.turnover_opportunities, value)).property_id IN (#{property_ids(index)})"}

      true ->
        :none
    end
  end

  defp clause(table, action, index) do
    cond do
      MapSet.member?(@catalog, table) and action == "select" ->
        :open

      MapSet.member?(@catalog, table) ->
        {:error, :forbidden}

      MapSet.member?(@directory_select, table) and action == "select" ->
        :open

      table == "bookings" and action != "select" ->
        {:error, :forbidden}

      column = force_column(table) ->
        {:ok, "#{table}.#{column}::text = $#{index}::text"}

      table in ["bookings", "conversations", "conversation_list", "subscriptions"] ->
        {:ok, party(table, ["customer_id", "cleaner_id"], index)}

      table == "jobs" and action == "select" ->
        {:ok,
         "#{party("jobs", ["customer_id", "claimed_by"], index)} OR (jobs.status = 'pending' AND jobs.claimed_by IS NULL)"}

      table == "jobs" ->
        {:ok, party("jobs", ["customer_id", "claimed_by"], index)}

      table == "transactions" ->
        {:ok, party("transactions", ["customer_id", "cleaner_id"], index)}

      table == "reviews" ->
        {:ok,
         "#{party("reviews", ["reviewer_id", "reviewee_id"], index)} OR reviews.booking_id IN (#{booking_ids(index)})"}

      table == "messages" ->
        {:ok, "messages.conversation_id IN (#{conversation_ids(index)})"}

      table in ["booking_micro_tasks", "booking_job_photos", "job_photo_comparisons", "cleaner_tracking"] ->
        {:ok, "#{table}.booking_id IN (#{booking_ids(index)})"}

      table == "job_offers" ->
        {:ok, "job_offers.cleaner_id::text = $#{index}::text OR job_offers.job_id IN (SELECT id FROM public.jobs WHERE customer_id::text = $#{index}::text)"}

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
  defp force_column("cleaner_devices"), do: "cleaner_id"
  defp force_column(_), do: nil

  defp party(table, columns, index) do
    Enum.map_join(columns, " OR ", fn column ->
      "#{table}.#{column}::text = $#{index}::text"
    end)
  end

  defp booking_ids(index) do
    "SELECT id FROM public.bookings WHERE customer_id::text = $#{index}::text OR cleaner_id::text = $#{index}::text"
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
