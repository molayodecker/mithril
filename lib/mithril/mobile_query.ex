defmodule Mithril.MobileQuery do
  @moduledoc """
  Compiles allowlisted table queries into parameterized SQL.

  The signed-in user id is applied by `Mithril.MobileScope` before the SQL
  runs. This module does not rely on Supabase row security.
  """

  @tables MapSet.new(~w(
    app_feature_flags
    app_update_policy
    auth_identity_lookup
    booking_job_photos
    booking_micro_tasks
    booking_settings
    bookings
    cleaner_application_drafts
    cleaner_applications
    cleaner_availability_exceptions
    cleaner_data
    cleaner_devices
    cleaner_tracking
    co_cleaner_invitations
    co_cleaner_relationships
    conversation_list
    conversations
    device_tokens
    extra_tasks
    job_offers
    job_photo_comparisons
    jobs
    kyc_profiles
    messages
    micro_task_options
    micro_tasks
    notifications
    payout_methods
    platform_fees
    preferred_cleaner_invitations
    preferred_cleaners
    profiles
    properties
    property_calendar_feeds
    property_media
    property_preferred_cleaners
    property_private_instructions
    reviews
    service_duration_options
    service_types
    subscriptions
    transactions
    turnover_opportunities
    user_profiles
    users
  ))

  # {parent_table, embed_table, constraint | nil} => {local_key, remote_key}
  @joins %{
    {"bookings", "service_types", nil} => {"service_id", "id"},
    {"bookings", "subscriptions", nil} => {"subscription_id", "id"},
    {"bookings", "users", "bookings_customer_id_fkey"} => {"customer_id", "id"},
    {"users", "profiles", nil} => {"id", "id"},
    {"transactions", "bookings", "transactions_booking_id_fkey"} => {"booking_id", "id"},
    {"booking_micro_tasks", "micro_tasks", nil} => {"micro_task_id", "id"},
    {"messages", "profiles", "messages_sender_id_fkey"} => {"sender_id", "id"},
    {"conversations", "profiles", "conversations_customer_id_fkey"} => {"customer_id", "id"},
    {"conversations", "profiles", "conversations_cleaner_id_fkey"} => {"cleaner_id", "id"}
  }

  @ident ~r/^[a-z_][a-z0-9_]*$/

  @secret_columns MapSet.new(~w(
    password_hash
    encrypted_password
    feed_url_encrypted
  ))

  @ownership_columns MapSet.new(~w(
    id
    user_id
    customer_id
    cleaner_id
    owner_id
    claimed_by
    reviewer_id
    sender_id
    inviter_user_id
  ))

  @money_columns MapSet.new(~w(
    payment_status
    payment_method
    reference
    final_amount_minor
    total_price
    platform_fee
    tax_share_minor
    vendor_share_minor
    platform_share_minor
    duration_hours
    duration_final
    kyc_status
    kyc_provider
    review_answer
  ))

  @embedded_columns %{
    "users" => MapSet.new(~w(id)),
    "profiles" => MapSet.new(~w(id firstname lastname fullname avatar_url))
  }

  @directory_columns %{
    "cleaner_data" => MapSet.new(~w(
        user_id
        verified
        status
        hourly_rate
        service_categories
        specialties
        rating
        completed_jobs
        intro_video_url
        intro_video_thumbnail_url
      ))
  }

  @safe_user_columns MapSet.new(~w(id email phone status created_at updated_at))

  @allowed_mutations %{
    "cleaner_application_drafts" => MapSet.new(~w(insert update upsert delete)),
    "cleaner_availability_exceptions" => MapSet.new(~w(insert update upsert delete)),
    "cleaner_devices" => MapSet.new(~w(insert update upsert delete)),
    "cleaner_tracking" => MapSet.new(~w(insert)),
    "device_tokens" => MapSet.new(~w(insert update upsert delete)),
    "messages" => MapSet.new(~w(insert)),
    "notifications" => MapSet.new(~w(update)),
    "payout_methods" => MapSet.new(~w(insert delete)),
    "preferred_cleaners" => MapSet.new(~w(insert delete)),
    "profiles" => MapSet.new(~w(insert update upsert)),
    "properties" => MapSet.new(~w(insert update delete)),
    "property_calendar_feeds" => MapSet.new(~w(insert update delete)),
    "property_media" => MapSet.new(~w(insert delete)),
    "property_preferred_cleaners" => MapSet.new(~w(insert delete)),
    "property_private_instructions" => MapSet.new(~w(insert update upsert delete))
  }

  @insert_columns %{
    "cleaner_application_drafts" =>
      MapSet.new(~w(user_id email payload current_step last_saved_at updated_at)),
    "cleaner_availability_exceptions" => MapSet.new(~w(cleaner_id exception_date reason)),
    "cleaner_devices" => MapSet.new(~w(cleaner_id expo_push_token platform updated_at)),
    "cleaner_tracking" =>
      MapSet.new(~w(booking_id cleaner_id latitude longitude accuracy heading)),
    "device_tokens" =>
      MapSet.new(
        ~w(user_id token platform android_notification_channel_version app_version updated_at)
      ),
    "messages" => MapSet.new(~w(conversation_id sender_id content)),
    "payout_methods" => MapSet.new(~w(
        user_id
        purpose
        type
        recipient_code
        account_name
        account_number
        masked_account
        bank_code
        bank_name
        network
        is_default
      )),
    "preferred_cleaners" => MapSet.new(~w(user_id cleaner_id)),
    "profiles" =>
      MapSet.new(
        ~w(id user_id firstname lastname fullname avatar_url address location_wkt updated_at)
      ),
    "properties" => MapSet.new(~w(
        customer_id
        name
        address
        timezone
        property_type
        is_default
        bedroom_count
        bathroom_count
        default_duration_hours
        provides_cleaning_supplies
        wash_dry_linen
        turnover_defaults_confirmed
        location_coordinates
        updated_at
      )),
    "property_calendar_feeds" => MapSet.new(~w(owner_id property_id name source updated_at)),
    "property_media" =>
      MapSet.new(~w(owner_id property_id media_type storage_path caption sort_order)),
    "property_preferred_cleaners" => MapSet.new(~w(owner_id property_id cleaner_id)),
    "property_private_instructions" =>
      MapSet.new(
        ~w(owner_id property_id wifi_network wifi_password parking_notes other_notes updated_at)
      )
  }

  @update_columns %{
    "cleaner_application_drafts" =>
      MapSet.new(~w(email payload current_step last_saved_at updated_at)),
    "cleaner_availability_exceptions" => MapSet.new(~w(exception_date reason)),
    "cleaner_devices" => MapSet.new(~w(expo_push_token platform updated_at)),
    "device_tokens" =>
      MapSet.new(~w(token platform android_notification_channel_version app_version updated_at)),
    "notifications" => MapSet.new(~w(read)),
    "profiles" =>
      MapSet.new(~w(firstname lastname fullname avatar_url address location_wkt updated_at)),
    "properties" => MapSet.new(~w(
        name
        address
        timezone
        property_type
        is_default
        bedroom_count
        bathroom_count
        default_duration_hours
        provides_cleaning_supplies
        wash_dry_linen
        turnover_defaults_confirmed
        location_coordinates
        updated_at
      )),
    "property_calendar_feeds" => MapSet.new(~w(name source updated_at)),
    "property_private_instructions" =>
      MapSet.new(~w(wifi_network wifi_password parking_notes other_notes updated_at))
  }

  def compile(user_id, query) when is_binary(user_id) and is_map(query) do
    table = query["table"]
    action = query["action"]

    with :ok <- validate_table(table),
         :ok <- validate_action(action),
         :ok <- validate_mutation(table, action) do
      compile_action(action, table, query, user_id)
    end
  end

  def compile(_user_id, _query), do: {:error, :invalid_query}

  defp compile_action("select", table, query, user_id) do
    embeds = query["embeds"] || []
    filters = query["filters"] || []
    {embed_filters, root_filters} = Enum.split_with(filters, &embed_filter?(&1, embeds))

    with :ok <- validate_projection(table, query["columns"] || ["*"]),
         {:ok, object_sql, params, required_embeds} <-
           object_sql(table, query["columns"] || ["*"], embeds, embed_filters, []),
         {:ok, where_sql, where_params} <-
           filters_sql(table, root_filters, length(params) + 1, embeds),
         {:ok, order_sql} <- order_sql(table, query["order"] || []),
         {:ok, limit_sql, _params} <- limit_sql(query, []) do
      where_sql = append_required_embeds(where_sql, required_embeds)
      params = params ++ where_params

      with {:ok, where_sql, params} <-
             Mithril.MobileScope.apply(user_id, "select", table, where_sql, params) do
        sql =
          if query["head"] == true do
            """
            SELECT count(*)::int
            FROM public.#{table}
            #{where_sql}
            """
          else
            """
            SELECT COALESCE(jsonb_agg(payload), '[]'::jsonb)
            FROM (
              SELECT #{object_sql} AS payload
              FROM public.#{table}
              #{where_sql}
              #{order_sql}
              #{limit_sql}
            ) rows
            """
          end

        {:ok, %{sql: sql, params: params}}
      end
    end
  end

  defp compile_action(action, table, query, user_id) when action in ["insert", "upsert"] do
    rows = normalize_rows(query["rows"])

    with {:ok, rows} <- Mithril.MobileScope.prepare_rows(user_id, table, rows),
         :ok <- validate_rows(rows),
         {:ok, columns} <- row_columns(table, rows),
         :ok <- validate_returning(table, query["returning"]),
         {:ok, conflict} <- conflict_target(query["onConflict"], action) do
      payload_param = "$1::jsonb"
      column_sql = Enum.map_join(columns, ", ", & &1)

      value_sql =
        Enum.map_join(columns, ", ", fn column ->
          "(jsonb_populate_record(NULL::public.#{table}, value)).#{column}"
        end)

      conflict_sql =
        case {action, conflict, Mithril.MobileScope.mutation_predicate(table, 2)} do
          {"upsert", targets, {:ok, predicate}} ->
            updates =
              Enum.map_join(columns, ", ", fn column ->
                "#{column} = EXCLUDED.#{column}"
              end)

            "ON CONFLICT (#{Enum.join(targets, ", ")}) DO UPDATE SET #{updates} WHERE #{predicate}"

          {"upsert", _targets, {:error, reason}} ->
            throw({:scope, reason})

          _ ->
            ""
        end

      returning = returning_sql(table, query["returning"])

      {guard_sql, params} =
        case {Mithril.MobileScope.insert_guard(table, 2), action} do
          {{:ok, guard}, _} -> {guard, [rows, user_id]}
          {:none, "upsert"} -> {"", [rows, user_id]}
          {:none, _} -> {"", [rows]}
        end

      sql = """
      INSERT INTO public.#{table} (#{column_sql})
      SELECT #{value_sql}
      FROM jsonb_array_elements(#{payload_param}) AS value
      WHERE TRUE
      #{guard_sql}
      #{conflict_sql}
      #{returning}
      """

      {:ok, %{sql: sql, params: params}}
    end
  catch
    {:scope, reason} -> {:error, reason}
  end

  defp compile_action("update", table, query, user_id) do
    patch = query["patch"] || %{}

    with :ok <- validate_patch(table, patch),
         :ok <- validate_returning(table, query["returning"]),
         {:ok, where_sql, params} <- filters_sql(table, query["filters"] || [], 2, []),
         {:ok, where_sql, params} <-
           Mithril.MobileScope.apply(user_id, "update", table, where_sql, params) do
      columns = Map.keys(patch)

      set_sql =
        Enum.map_join(columns, ", ", fn column ->
          "#{column} = (jsonb_populate_record(NULL::public.#{table}, $1::jsonb)).#{column}"
        end)

      returning = returning_sql(table, query["returning"])

      sql = """
      UPDATE public.#{table} AS #{table}
      SET #{set_sql}
      #{where_sql}
      #{returning}
      """

      {:ok, %{sql: sql, params: [patch | params]}}
    end
  end

  defp compile_action("delete", table, query, user_id) do
    with :ok <- validate_returning(table, query["returning"]),
         {:ok, where_sql, params} <- filters_sql(table, query["filters"] || [], 1, []),
         {:ok, where_sql, params} <-
           Mithril.MobileScope.apply(user_id, "delete", table, where_sql, params) do
      returning = returning_sql(table, query["returning"])

      sql = """
      DELETE FROM public.#{table} AS #{table}
      #{where_sql}
      #{returning}
      """

      {:ok, %{sql: sql, params: params}}
    end
  end

  defp object_sql(table, columns, embeds, embed_filters, params, kind \\ :root) do
    with {:ok, columns} <- expand_columns(table, columns, kind) do
      base =
        cond do
          "*" in columns ->
            redact_wildcard_sql(table)

          columns == [] ->
            "'{}'::jsonb"

          true ->
            pairs =
              Enum.map_join(columns, ", ", fn column -> "'#{column}', #{table}.#{column}" end)

            "jsonb_build_object(#{pairs})"
        end

      Enum.reduce_while(embeds, {:ok, base, params, []}, fn embed, {:ok, acc, params, required} ->
        case embed_sql(table, embed, embed_filters, params) do
          {:ok, sql, params, embed_required} ->
            alias_name = embed["alias"] || embed["table"]
            merged = "(#{acc} || jsonb_build_object('#{alias_name}', #{sql}))"
            required = if embed_required, do: [sql | required], else: required
            {:cont, {:ok, merged, params, required}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp append_required_embeds(where_sql, []), do: where_sql

  defp append_required_embeds(where_sql, required) do
    extra = Enum.map_join(required, " AND ", fn sql -> "(#{sql}) IS NOT NULL" end)

    if where_sql == "" do
      "WHERE " <> extra
    else
      where_sql <> " AND " <> extra
    end
  end

  defp embed_sql(parent, embed, parent_filters, params) do
    child = embed["table"]
    constraint = blank_to_nil(embed["constraint"])
    alias_name = embed["alias"] || child

    with :ok <- validate_table(child),
         :ok <- validate_ident(alias_name),
         {:ok, {local_key, remote_key}} <- join_keys(parent, child, constraint),
         :ok <- validate_projection(child, embed["columns"] || ["*"], :embed) do
      child_filters =
        Enum.flat_map(parent_filters, fn
          %{"op" => "not", "filter" => inner} = filter ->
            case strip_embed_column(inner, alias_name, child) do
              {:ok, rewritten} -> [Map.put(filter, "filter", rewritten)]
              :skip -> []
            end

          filter ->
            case strip_embed_column(filter, alias_name, child) do
              {:ok, rewritten} -> [rewritten]
              :skip -> []
            end
        end)

      with {:ok, filter_sql, filter_params} <-
             filters_sql(child, child_filters ++ (embed["filters"] || []), length(params) + 1, []) do
        params = params ++ filter_params
        columns = embed["columns"] || ["*"]
        nested = embed["embeds"] || []

        with {:ok, projected, params, nested_required} <-
               object_sql(child, columns, nested, [], params, :embed) do
          join_sql = "#{child}.#{remote_key} = #{parent}.#{local_key}"

          where_sql =
            if filter_sql == "" do
              "WHERE #{join_sql}"
            else
              filter_sql <> " AND " <> join_sql
            end

          where_sql = append_required_embeds(where_sql, nested_required)

          sql = """
          (
            SELECT #{projected}
            FROM public.#{child}
            #{where_sql}
          )
          """

          required = embed["inner"] == true or child_filters != []
          {:ok, sql, params, required}
        end
      end
    end
  end

  defp strip_embed_column(%{"column" => column} = filter, alias_name, child) do
    case String.split(column, ".", parts: 2) do
      [^alias_name, field] -> {:ok, Map.put(filter, "column", field)}
      [^child, field] -> {:ok, Map.put(filter, "column", field)}
      _ -> :skip
    end
  end

  defp strip_embed_column(_, _, _), do: :skip

  defp embed_filter?(%{"op" => "not", "filter" => inner}, embeds),
    do: embed_filter?(inner, embeds)

  defp embed_filter?(%{"column" => column}, embeds) when is_binary(column) do
    case String.split(column, ".", parts: 2) do
      [prefix, _field] ->
        Enum.any?(embeds, fn embed ->
          alias_name = embed["alias"] || embed["table"]
          alias_name == prefix or embed["table"] == prefix
        end)

      _ ->
        false
    end
  end

  defp embed_filter?(_, _), do: false

  defp join_keys(parent, child, constraint) do
    case Map.fetch(@joins, {parent, child, constraint}) do
      {:ok, keys} -> {:ok, keys}
      :error -> {:error, :unknown_embed}
    end
  end

  defp filters_sql(_table, [], _index, _embeds), do: {:ok, "", []}

  defp filters_sql(table, filters, index, embeds) when is_list(filters) do
    {parts, params, _index} =
      Enum.reduce(filters, {[], [], index}, fn filter, {parts, params, index} ->
        case filter_sql(table, filter, index, embeds) do
          {:ok, sql, extra, next} -> {[sql | parts], params ++ extra, next}
          {:error, reason} -> throw({:filter, reason})
        end
      end)

    sql = "WHERE " <> Enum.join(Enum.reverse(parts), " AND ")
    {:ok, sql, params}
  catch
    {:filter, reason} -> {:error, reason}
  end

  defp filters_sql(_, _, _, _), do: {:error, :invalid_filter}

  defp filter_sql(table, %{"op" => "or", "filters" => nested}, index, embeds)
       when is_list(nested) and nested != [] do
    {parts, params, next} =
      Enum.reduce(nested, {[], [], index}, fn filter, {parts, params, index} ->
        case filter_sql(table, filter, index, embeds) do
          {:ok, sql, extra, next} -> {[sql | parts], params ++ extra, next}
          {:error, reason} -> throw({:filter, reason})
        end
      end)

    {:ok, "(" <> Enum.join(Enum.reverse(parts), " OR ") <> ")", params, next}
  end

  defp filter_sql(table, %{"op" => "not", "filter" => inner}, index, embeds) when is_map(inner) do
    with {:ok, sql, params, next} <- filter_sql(table, inner, index, embeds) do
      {:ok, "NOT (" <> sql <> ")", params, next}
    end
  end

  defp filter_sql(table, %{"op" => op, "column" => column} = filter, index, _embeds) do
    with {:ok, qualified} <- qualify_column(table, column) do
      case op do
        "is" ->
          case is_sql(qualified, filter["value"]) do
            {:ok, sql} -> {:ok, sql, [], index}
            {:error, reason} -> {:error, reason}
          end

        "in" ->
          values = filter["value"] || []

          if values == [] do
            {:ok, "FALSE", [], index}
          else
            {:ok, "#{qualified}::text = ANY($#{index}::text[])", [Enum.map(values, &to_string/1)],
             index + 1}
          end

        "ilike" ->
          {:ok, "#{qualified}::text ILIKE $#{index}::text", [stringify(filter["value"])],
           index + 1}

        binary when binary in ["eq", "neq", "gt", "gte", "lt", "lte"] ->
          operator =
            case binary do
              "eq" -> "="
              "neq" -> "<>"
              "gt" -> ">"
              "gte" -> ">="
              "lt" -> "<"
              "lte" -> "<="
            end

          {:ok, "#{qualified}::text #{operator} $#{index}::text", [stringify(filter["value"])],
           index + 1}

        "contains" ->
          values = filter["value"] || []

          {:ok, "#{qualified}::text[] @> $#{index}::text[]", [Enum.map(values, &to_string/1)],
           index + 1}

        _ ->
          {:error, :invalid_filter}
      end
    end
  end

  defp filter_sql(_, _, _, _), do: {:error, :invalid_filter}

  defp is_sql(qualified, value) when value in [nil, "null"], do: {:ok, "#{qualified} IS NULL"}
  defp is_sql(qualified, value) when value in [false, "false"], do: {:ok, "#{qualified} IS FALSE"}
  defp is_sql(qualified, value) when value in [true, "true"], do: {:ok, "#{qualified} IS TRUE"}
  defp is_sql(_qualified, _value), do: {:error, :invalid_filter}

  defp qualify_column(table, column) when is_binary(column) do
    case String.split(column, ".", parts: 2) do
      [field] ->
        with :ok <- validate_ident(field),
             :ok <- validate_query_column(table, field) do
          {:ok, "#{table}.#{field}"}
        end

      [prefix, field] ->
        with :ok <- validate_ident(prefix),
             :ok <- validate_ident(field),
             :ok <- validate_query_column(table, field) do
          if prefix == table do
            {:ok, "#{table}.#{field}"}
          else
            {:error, :invalid_filter}
          end
        end
    end
  end

  defp qualify_column(_, _), do: {:error, :invalid_filter}

  defp order_sql(_table, []), do: {:ok, ""}

  defp order_sql(table, orders) when is_list(orders) do
    parts =
      Enum.map(orders, fn order ->
        column = order["column"]
        direction = if order["ascending"] == false, do: "DESC", else: "ASC"

        nulls =
          case order["nullsFirst"] do
            true -> " NULLS FIRST"
            false -> " NULLS LAST"
            _ -> ""
          end

        with :ok <- validate_ident(column),
             :ok <- validate_query_column(table, column) do
          "#{table}.#{column} #{direction}#{nulls}"
        else
          {:error, reason} -> throw({:order, reason})
        end
      end)

    {:ok, "ORDER BY " <> Enum.join(parts, ", ")}
  catch
    {:order, reason} -> {:error, reason}
  end

  defp order_sql(_, _), do: {:error, :invalid_order}

  defp limit_sql(query, params) do
    limit = query["limit"]
    offset = query["offset"] || 0

    cond do
      not is_nil(limit) and (not is_integer(limit) or limit < 1 or limit > 5000) ->
        {:error, :invalid_limit}

      not is_integer(offset) or offset < 0 ->
        {:error, :invalid_limit}

      is_nil(limit) and offset == 0 ->
        {:ok, "", params}

      is_nil(limit) ->
        {:ok, "OFFSET #{offset}", params}

      true ->
        {:ok, "LIMIT #{limit} OFFSET #{offset}", params}
    end
  end

  defp validate_returning(_table, nil), do: :ok
  defp validate_returning(_table, []), do: :ok

  defp validate_returning(table, columns) when is_list(columns) do
    validate_projection(table, columns)
  end

  defp validate_returning(_table, _), do: {:error, :invalid_column}

  defp returning_sql(_table, nil), do: ""
  defp returning_sql(_table, []), do: ""

  defp returning_sql(table, returning) when is_list(returning) do
    cond do
      "*" in returning ->
        "RETURNING #{redact_wildcard_sql(table)}"

      true ->
        pairs = Enum.map_join(returning, ", ", fn column -> "'#{column}', #{table}.#{column}" end)
        "RETURNING jsonb_build_object(#{pairs})"
    end
  end

  defp returning_sql(_, _), do: ""

  defp normalize_rows(row) when is_map(row), do: [row]
  defp normalize_rows(rows) when is_list(rows), do: rows
  defp normalize_rows(_), do: :invalid

  defp validate_rows(:invalid), do: {:error, :invalid_rows}
  defp validate_rows([]), do: {:error, :invalid_rows}

  defp validate_rows(rows) do
    if Enum.all?(rows, &is_map/1), do: :ok, else: {:error, :invalid_rows}
  end

  defp row_columns(table, rows) do
    columns =
      rows
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    cond do
      columns == [] ->
        {:error, :invalid_rows}

      Enum.any?(columns, &(validate_ident(&1) != :ok)) ->
        {:error, :invalid_column}

      Enum.any?(columns, &protected_write_column?/1) ->
        {:error, :forbidden}

      not writable_columns?(table, "insert", columns) ->
        {:error, :forbidden}

      true ->
        {:ok, columns}
    end
  end

  defp validate_patch(table, patch) when is_map(patch) and map_size(patch) > 0 do
    keys = Map.keys(patch)

    cond do
      Enum.any?(keys, &(validate_ident(&1) != :ok)) ->
        {:error, :invalid_column}

      Enum.any?(keys, &protected_write_column?/1) ->
        {:error, :forbidden}

      Enum.any?(keys, &MapSet.member?(@ownership_columns, &1)) ->
        {:error, :forbidden}

      not writable_columns?(table, "update", keys) ->
        {:error, :forbidden}

      true ->
        :ok
    end
  end

  defp validate_patch(_table, _), do: {:error, :invalid_rows}

  defp conflict_target(_value, "insert"), do: {:ok, []}

  defp conflict_target(value, "upsert") when is_binary(value) do
    targets = value |> String.split(",") |> Enum.map(&String.trim/1)

    if targets != [] and Enum.all?(targets, &(validate_ident(&1) == :ok)) do
      {:ok, targets}
    else
      {:error, :invalid_column}
    end
  end

  defp conflict_target(_, "upsert"), do: {:error, :invalid_column}

  defp validate_columns(columns) when is_list(columns) do
    if Enum.all?(columns, fn
         "*" -> true
         column when is_binary(column) -> validate_ident(column) == :ok
         _ -> false
       end) do
      :ok
    else
      {:error, :invalid_column}
    end
  end

  defp validate_columns(_), do: {:error, :invalid_column}

  defp validate_table(table) do
    if is_binary(table) and MapSet.member?(@tables, table),
      do: :ok,
      else: {:error, :unknown_table}
  end

  defp validate_action(action) when action in ["select", "insert", "update", "delete", "upsert"],
    do: :ok

  defp validate_action(_), do: {:error, :invalid_query}

  defp validate_mutation(_table, "select"), do: :ok

  defp validate_mutation(table, action) do
    case Map.get(@allowed_mutations, table) do
      %MapSet{} = allowed ->
        if MapSet.member?(allowed, action), do: :ok, else: {:error, :forbidden}

      _ ->
        {:error, :forbidden}
    end
  end

  defp writable_columns?(table, action, columns) do
    allowed =
      case action do
        "insert" -> Map.get(@insert_columns, table)
        "update" -> Map.get(@update_columns, table)
        _ -> nil
      end

    is_struct(allowed, MapSet) and Enum.all?(columns, &MapSet.member?(allowed, &1))
  end

  defp validate_projection(table, columns, kind \\ :root)

  defp validate_projection(table, columns, kind) when is_list(columns) do
    case expand_columns(table, columns, kind) do
      {:ok, _columns} -> :ok
      error -> error
    end
  end

  defp validate_projection(_table, _columns, _kind), do: {:error, :invalid_column}

  defp expand_columns(table, columns, kind) do
    with :ok <- validate_columns(columns) do
      requested = if "*" in columns, do: wildcard_columns(table, kind), else: columns

      cond do
        requested == :wildcard ->
          {:ok, ["*"]}

        Enum.any?(List.wrap(requested), &secret_column?/1) ->
          {:error, :forbidden}

        not allowed_columns?(table, List.wrap(requested), kind) ->
          {:error, :forbidden}

        true ->
          {:ok, List.wrap(requested)}
      end
    end
  end

  defp wildcard_columns(table, :embed) do
    case Map.get(@embedded_columns, table) do
      nil -> :wildcard
      allowed -> MapSet.to_list(allowed)
    end
  end

  defp wildcard_columns(table, :root) do
    cond do
      Map.has_key?(@directory_columns, table) ->
        MapSet.to_list(Map.fetch!(@directory_columns, table))

      table == "users" ->
        MapSet.to_list(@safe_user_columns)

      true ->
        :wildcard
    end
  end

  defp allowed_columns?(table, columns, :embed) do
    case Map.get(@embedded_columns, table) do
      nil -> Enum.all?(columns, &(not secret_column?(&1)))
      allowed -> Enum.all?(columns, &MapSet.member?(allowed, &1))
    end
  end

  defp allowed_columns?(table, columns, :root) do
    cond do
      Map.has_key?(@directory_columns, table) ->
        allowed = Map.fetch!(@directory_columns, table)
        Enum.all?(columns, &MapSet.member?(allowed, &1))

      table == "users" ->
        Enum.all?(columns, &MapSet.member?(@safe_user_columns, &1))

      true ->
        Enum.all?(columns, &(not secret_column?(&1)))
    end
  end

  defp redact_wildcard_sql(table) do
    Enum.reduce(@secret_columns, "to_jsonb(#{table})", fn column, acc ->
      "(#{acc} - '#{column}')"
    end)
  end

  defp secret_column?(column), do: MapSet.member?(@secret_columns, column)

  defp validate_query_column(table, column) do
    cond do
      secret_column?(column) ->
        {:error, :forbidden}

      Map.has_key?(@directory_columns, table) ->
        if MapSet.member?(Map.fetch!(@directory_columns, table), column),
          do: :ok,
          else: {:error, :forbidden}

      table == "users" ->
        if MapSet.member?(@safe_user_columns, column), do: :ok, else: {:error, :forbidden}

      true ->
        :ok
    end
  end

  defp protected_write_column?(column) do
    secret_column?(column) or MapSet.member?(@money_columns, column)
  end

  defp validate_ident(name) when is_binary(name) do
    if Regex.match?(@ident, name), do: :ok, else: {:error, :invalid_column}
  end

  defp validate_ident(_), do: {:error, :invalid_column}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
