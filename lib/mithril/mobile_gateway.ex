defmodule Mithril.MobileGateway do
  @moduledoc false

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
        with {:ok, kind} <- return_kind(compiled.name) do
          query(MobileRpc.sql(compiled, kind), compiled.params, kind != :void)
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

  defp return_kind(name) do
    sql = """
    SELECT p.proretset, pg_catalog.format_type(p.prorettype, NULL)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = $1
    """

    case Repo.query(sql, [name]) do
      {:ok, %{rows: []}} ->
        {:error, :unknown_function}

      {:ok, %{rows: rows}} ->
        cond do
          Enum.any?(rows, fn [set?, _type] -> set? end) -> {:ok, :set}
          Enum.any?(rows, fn [_set?, type] -> type == "void" end) -> {:ok, :void}
          true -> {:ok, :scalar}
        end

      {:error, error} ->
        {:error, error}
    end
  end

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
