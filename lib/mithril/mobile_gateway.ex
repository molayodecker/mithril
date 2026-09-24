defmodule Mithril.MobileGateway do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.MobileFunctions
  alias Mithril.MobileQuery
  alias Mithril.MobileRpc
  alias Mithril.Repo

  @functions MapSet.new(~w(
    cancel-subscription
    connect-property-calendar
    claim-job
    create-job-and-notify
    delete-property-media
    fetch-otp-delivery-token
    notify-booking-rescheduled
    notify-payment-failure-ops
    paystack-create-transfer-recipient
    paystack-fetch-banks
    paystack-initiate-transfer
    paystack-resolve-bank-account
    rank-cleaners-with-ai
    request-data-export
    resend-otp-via-channel
    send-app-notification
    send-notification
    sumsub-config/token
    sync-sumsub-review
    timezone
    uber-transportation-release-gate
    uber-trip-estimate
  ))

  @migrated_functions @functions

  @safe_embedded_user_columns MapSet.new(~w(id))
  @safe_embedded_profile_columns MapSet.new(~w(id firstname lastname fullname avatar_url))

  def call_rpc(user_id, name, args) do
    with {:ok, compiled} <- MobileRpc.compile(name, args || %{}) do
      transact(user_id, fn ->
        with {:ok, signature} <- resolve_signature(compiled.name, compiled.arg_names),
             {:ok, params} <- normalize_rpc_params(compiled, signature) do
          query(
            MobileRpc.sql(compiled, signature.kind),
            params,
            signature.kind != :void
          )
        end
      end)
    end
  end

  def run_query(user_id, query) do
    with :ok <- validate_query_boundary(query),
         {:ok, compiled} <- MobileQuery.compile(user_id, query) do
      transact(user_id, fn -> query(compiled.sql, compiled.params, true) end)
    end
  end

  def invoke_function(user_id, name, body) when is_binary(name) and is_map(body) do
    cond do
      MapSet.member?(@migrated_functions, name) ->
        MobileFunctions.invoke(user_id, name, body)

      MapSet.member?(@functions, name) ->
        {:error, :function_not_migrated}

      true ->
        {:error, :unknown_function}
    end
  end

  def invoke_function(_user_id, _name, _body), do: {:error, :bad_request}

  def with_user_transaction(user_id, fun) when is_function(fun, 0) do
    transact(user_id, fun)
  end

  def function_route(name) when is_binary(name) do
    if MapSet.member?(@functions, name) do
      {:error, :function_not_migrated}
    else
      {:error, :unknown_function}
    end
  end

  def function_route(_), do: {:error, :unknown_function}

  defp validate_query_boundary(%{"table" => "property_calendar_feeds"} = query) do
    columns = query["columns"] || ["*"]
    returning = query["returning"] || []

    cond do
      "feed_url_encrypted" in columns -> {:error, :forbidden}
      "feed_url_encrypted" in returning -> {:error, :forbidden}
      query["action"] != "select" and "*" in returning -> {:error, :forbidden}
      true -> validate_embeds(query["embeds"] || [])
    end
  end

  defp validate_query_boundary(query) when is_map(query) do
    validate_embeds(query["embeds"] || [])
  end

  defp validate_query_boundary(_), do: {:error, :invalid_query}

  defp validate_embeds(embeds) when is_list(embeds) do
    Enum.reduce_while(embeds, :ok, fn embed, :ok ->
      columns = embed["columns"] || ["*"]

      result =
        cond do
          embed["table"] == "users" and
              unsafe_embed_columns?(columns, @safe_embedded_user_columns) ->
            {:error, :forbidden}

          embed["table"] == "profiles" and
              unsafe_embed_columns?(columns, @safe_embedded_profile_columns) ->
            {:error, :forbidden}

          true ->
            validate_embeds(embed["embeds"] || [])
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_embeds(_), do: {:error, :invalid_query}

  defp unsafe_embed_columns?(columns, allowed) do
    "*" in columns or Enum.any?(columns, &(not MapSet.member?(allowed, &1)))
  end

  defp transact(user_id, fun) do
    case Repo.transaction(fn ->
           with :ok <- assume_user(user_id),
                {:ok, value} <- fun.() do
             value
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assume_user(user_id) do
    claims = Jason.encode!(%{"sub" => user_id})

    with {:ok, _} <- Repo.query("SELECT set_config('request.jwt.claim.sub', $1, true)", [user_id]),
         {:ok, _} <- Repo.query("SELECT set_config('request.jwt.claims', $1, true)", [claims]) do
      :ok
    else
      {:error, %Postgrex.Error{} = error} -> {:error, error}
    end
  end

  defp resolve_signature(name, supplied_names) do
    sql = """
    SELECT p.proretset,
           pg_catalog.format_type(p.prorettype, NULL),
           p.pronargdefaults,
           COALESCE(
             jsonb_agg(
               jsonb_build_object(
                 'name', COALESCE(p.proargnames[arg.ord::int], ''),
                 'type', pg_catalog.format_type(arg.type_oid, NULL),
                 'ord', arg.ord
               )
               ORDER BY arg.ord
             ) FILTER (WHERE arg.ord IS NOT NULL),
             '[]'::jsonb
           )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    LEFT JOIN LATERAL
      unnest(p.proargtypes::oid[]) WITH ORDINALITY AS arg(type_oid, ord)
      ON true
    WHERE n.nspname = 'public'
      AND p.proname = $1
    GROUP BY p.oid, p.proretset, p.prorettype, p.pronargdefaults
    """

    case Repo.query(sql, [name]) do
      {:ok, %{rows: rows}} ->
        candidates =
          rows
          |> Enum.map(&signature_from_row/1)
          |> Enum.filter(&signature_accepts?(&1, supplied_names))

        case candidates do
          [signature] -> {:ok, signature}
          [] -> {:error, :unknown_function}
          _ -> {:error, :ambiguous_function}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp signature_from_row([set?, return_type, default_count, args]) do
    kind =
      cond do
        set? -> :set
        return_type == "void" -> :void
        true -> :scalar
      end

    %{
      kind: kind,
      default_count: default_count || 0,
      args: args || []
    }
  end

  defp signature_accepts?(signature, supplied_names) do
    names = Enum.map(signature.args, &Map.get(&1, "name", ""))
    supplied = MapSet.new(supplied_names)
    accepted = MapSet.new(names)
    required_count = max(length(names) - signature.default_count, 0)
    required = names |> Enum.take(required_count) |> MapSet.new()

    MapSet.subset?(supplied, accepted) and MapSet.subset?(required, supplied)
  end

  defp normalize_rpc_params(compiled, signature) do
    types =
      Map.new(signature.args, fn arg ->
        {Map.get(arg, "name"), Map.get(arg, "type")}
      end)

    compiled.arg_names
    |> Enum.zip(compiled.params)
    |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, acc} ->
      case normalize_rpc_value(Map.get(types, name), value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp normalize_rpc_value("uuid", value) when is_binary(value) do
    cond do
      byte_size(value) == 16 ->
        {:ok, value}

      true ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, DbUuid.dump!(uuid)}
          :error -> {:error, :invalid_args}
        end
    end
  end

  defp normalize_rpc_value("uuid[]", values) when is_list(values) do
    try do
      {:ok, DbUuid.dump_all!(values)}
    rescue
      ArgumentError -> {:error, :invalid_args}
    end
  end

  defp normalize_rpc_value("date", value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_args}
    end
  end

  defp normalize_rpc_value("time without time zone", value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      _ -> {:error, :invalid_args}
    end
  end

  defp normalize_rpc_value("timestamp without time zone", value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> {:error, :invalid_args}
    end
  end

  defp normalize_rpc_value("timestamp with time zone", value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_args}
    end
  end

  defp normalize_rpc_value("numeric", %Decimal{} = value), do: {:ok, value}
  defp normalize_rpc_value("numeric", value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp normalize_rpc_value("numeric", value) when is_float(value),
    do: {:ok, Decimal.from_float(value)}

  defp normalize_rpc_value("numeric", value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, :invalid_args}
    end
  end

  defp normalize_rpc_value(nil, _value), do: {:error, :invalid_args}
  defp normalize_rpc_value(_type, value), do: {:ok, value}

  defp query(sql, params, decode?) do
    case Repo.query(sql, params) do
      {:ok, %{rows: []}} when decode? -> {:ok, []}
      {:ok, %{rows: [[value]]}} when decode? -> {:ok, value}
      {:ok, %{rows: rows}} when decode? -> {:ok, Enum.map(rows, fn [value] -> value end)}
      {:ok, _result} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end
end
