defmodule Mithril.Schema.Check do
  @moduledoc false

  require Logger

  @query """
  SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relname = ANY($1::text[])
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :transient
    }
  end

  def start_link do
    if Application.get_env(:mithril, :verify_schema, true) do
      required = Mithril.Schema.RequiredTables.tables()

      case verify(required, Mithril.Repo.query(@query, [required])) do
        :ok ->
          :ignore

        {:error, {:schema_missing, missing}} = error ->
          Logger.error("Required tables are missing: #{Enum.join(missing, ", ")}")
          error

        {:error, {:schema_check_failed, _reason}} = error ->
          Logger.error("Required schema check failed")
          error
      end
    else
      :ignore
    end
  end

  @doc false
  def verify(_required, {:ok, %{rows: nil}}), do: {:error, {:schema_check_failed, :no_rows}}

  def verify(required, {:ok, %{rows: rows}}) when is_list(required) and is_list(rows) do
    present = for [name] <- rows, is_binary(name), do: name

    case missing(required, present) do
      [] -> :ok
      missing -> {:error, {:schema_missing, missing}}
    end
  end

  def verify(_required, {:error, reason}), do: {:error, {:schema_check_failed, reason}}
  def verify(_required, other), do: {:error, {:schema_check_failed, other}}

  @doc false
  def missing(required, present) when is_list(required) and is_list(present) do
    present = MapSet.new(present)
    Enum.reject(required, &MapSet.member?(present, &1))
  end
end
