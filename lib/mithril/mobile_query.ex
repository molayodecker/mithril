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

  def compile(user_id, query) when is_binary(user_id) and is_map(query) do
    table = query["table"]
    action = query["action"]

    with :ok <- validate_table(table),
         :ok <- validate_action(action) do
      compile_action(action, table, query, user_id)
    end
  end

  def compile(_user_id, _query), do: {:error, :invalid_query}

  defp compile_action("select", table, query, user_id) do
    embeds = query["embeds"] || []
    filters = query["filters"] || []
    {embed_filters, root_filters} = Enum.split_with(filters, &embed_filter?(&1, embeds))

    with :ok <- validate_columns(query["columns"] || ["*"]),
         {:ok, object_sql, params, required_embeds} <-
           object_sql(table, query["columns"] || ["*"], embeds, embed_filters, []),
         {:ok, where_sql, where_params} <-
           filters_sql(table, root_filters, length(params) + 1, embeds),
         {:ok, order_sql} <- order_sql(table, query["order"] || []),
         {:ok, limit_sql, _params} <- limit_sql(query, []) do
      where_sql = append_required_embeds(where_sql, required_embeds)
      params = params ++ where_params

      with {:ok, where_sql, params} <- Mithril.MobileScope.apply(user_id, "select", table, where_sql, params) do
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
         {:ok, columns} <- row_columns(rows),
         :ok <- validate_returning(query["returning"]),
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

    with :ok <- validate_patch(patch),
         :ok <- validate_returning(query["returning"]),
         {:ok, where_sql, params} <- filters_sql(table, query["filters"] || [], 2, []),
         {:ok, where_sql, params} <- Mithril.MobileScope.apply(user_id, "update", table, where_sql, params) do
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
    with :ok <- validate_returning(query["returning"]),
         {:ok, where_sql, params} <- filters_sql(table, query["filters"] || [], 1, []),
         {:ok, where_sql, params} <- Mithril.MobileScope.apply(user_id, "delete", table, where_sql, params) do
      returning = returning_sql(table, query["returning"])

      sql = """
      DELETE FROM public.#{table} AS #{table}
      #{where_sql}
      #{returning}
      """

      {:ok, %{sql: sql, params: params}}
    end
  end

  defp object_sql(table, columns, embeds, embed_filters, params) do
    base =
      cond do
        "*" in columns and table == "property_calendar_feeds" ->
          "(to_jsonb(#{table}) - 'feed_url_encrypted')"

        "*" in columns -> "to_jsonb(#{table})"
        columns == [] -> "'{}'::jsonb"
        true ->
          pairs = Enum.map_join(columns, ", ", fn column -> "'#{column}', #{table}.#{column}" end)
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
         :ok <- validate_columns(embed["columns"] || ["*"]) do
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
               object_sql(child, columns, nested, [], params) do
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

  defp embed_filter?(%{"op" => "not", "filter" => inner}, embeds), do: embed_filter?(inner, embeds)

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

  defp filter_sql(table, %{"op" => "or", "filters" => nested}, index, embeds) when is_list(nested) do
    {parts, params, next} =
      Enum.reduce(nested, {[], [], index}, fn filter, {parts, params, index} ->
        {:ok, sql, extra, next} = filter_sql(table, filter, index, embeds)
        {[sql | parts], params ++ extra, next}
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
          {:ok, null_sql(qualified, filter["value"]), [], index}

        "in" ->
          values = filter["value"] || []

          if values == [] do
            {:ok, "FALSE", [], index}
          else
            {:ok, "#{qualified}::text = ANY($#{index}::text[])", [Enum.map(values, &to_string/1)], index + 1}
          end

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

          {:ok, "#{qualified}::text #{operator} $#{index}::text", [stringify(filter["value"])], index + 1}

        "contains" ->
          values = filter["value"] || []
          {:ok, "#{qualified}::text[] @> $#{index}::text[]", [Enum.map(values, &to_string/1)], index + 1}

        _ ->
          {:error, :invalid_filter}
      end
    end
  end

  defp filter_sql(_, _, _, _), do: {:error, :invalid_filter}

  defp null_sql(qualified, value) when value in [nil, "null"] do
    "#{qualified} IS NULL"
  end

  defp null_sql(qualified, false), do: "#{qualified} IS NULL"
  defp null_sql(qualified, true), do: "#{qualified} IS NOT NULL"
  defp null_sql(qualified, _), do: "#{qualified} IS NOT NULL"

  defp qualify_column(table, column) when is_binary(column) do
    case String.split(column, ".", parts: 2) do
      [field] ->
        with :ok <- validate_ident(field), do: {:ok, "#{table}.#{field}"}

      [prefix, field] ->
        with :ok <- validate_ident(prefix),
             :ok <- validate_ident(field) do
          {:ok, "#{prefix}.#{field}"}
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

        case validate_ident(column) do
          :ok -> "#{table}.#{column} #{direction}#{nulls}"
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

  defp validate_returning(nil), do: :ok
  defp validate_returning([]), do: :ok

  defp validate_returning(columns) when is_list(columns) do
    if Enum.all?(columns, fn
         "*" -> true
         column -> validate_ident(column) == :ok
       end) do
      :ok
    else
      {:error, :invalid_column}
    end
  end

  defp validate_returning(_), do: {:error, :invalid_column}

  defp returning_sql(_table, nil), do: ""
  defp returning_sql(_table, []), do: ""

  defp returning_sql(table, returning) when is_list(returning) do
    if "*" in returning do
      "RETURNING to_jsonb(#{table})"
    else
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

  defp row_columns(rows) do
    columns =
      rows
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    if columns == [] do
      {:error, :invalid_rows}
    else
      case Enum.find(columns, &(validate_ident(&1) != :ok)) do
        nil -> {:ok, columns}
        _ -> {:error, :invalid_column}
      end
    end
  end

  defp validate_patch(patch) when is_map(patch) and map_size(patch) > 0 do
    if Enum.all?(Map.keys(patch), &(validate_ident(&1) == :ok)), do: :ok, else: {:error, :invalid_column}
  end

  defp validate_patch(_), do: {:error, :invalid_rows}

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
    if is_binary(table) and MapSet.member?(@tables, table), do: :ok, else: {:error, :unknown_table}
  end

  defp validate_action(action) when action in ["select", "insert", "update", "delete", "upsert"], do: :ok
  defp validate_action(_), do: {:error, :invalid_query}

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
