defmodule Mithril.MobileGateway do
  @moduledoc false

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
    with {:ok, compiled} <- MobileQuery.compile(user_id, query) do
      transact(user_id, fn -> query(compiled.sql, compiled.params, true) end)
    end
  end

  def function_route(name) when is_binary(name) do
    if MapSet.member?(@functions, name) do
      {:error, :function_not_migrated}
    else
      {:error, :unknown_function}
    end
  end

  def function_route(_), do: {:error, :unknown_function}

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
