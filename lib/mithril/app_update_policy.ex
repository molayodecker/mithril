defmodule Mithril.AppUpdatePolicy do
  @moduledoc """
  Reads one store-update policy for an app and release channel.

  Zero rows return nil. More than one row is an error. That is the
  maybe-single contract the mobile gate depends on.
  """

  require Logger

  alias Mithril.Repo

  @apps ~w(customer worker)
  @channels ~w(production preview)

  def fetch(app, channel) when app in @apps and channel in @channels do
    case Repo.query(
           """
           SELECT jsonb_build_object(
             'app', app,
             'channel', channel,
             'min_version', min_version,
             'recommended_version', recommended_version,
             'required_message', required_message,
             'recommended_message', recommended_message
           )
           FROM public.app_update_policy
           WHERE app = $1 AND channel = $2
           LIMIT 2
           """,
           [app, channel]
         ) do
      {:ok, %{num_rows: 0}} ->
        {:ok, nil}

      {:ok, %{num_rows: 1, rows: [[policy]]}} ->
        {:ok, policy}

      {:ok, %{num_rows: count}} when count > 1 ->
        {:error, :multiple_rows}

      {:error, error} ->
        database_error(error)
    end
  end

  def fetch(_app, _channel), do: {:error, :bad_request}

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("App update policy read failed: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
