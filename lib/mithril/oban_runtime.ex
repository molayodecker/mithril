defmodule Mithril.ObanRuntime do
  @moduledoc false

  require Logger

  def child_spec(_opts) do
    %{
      id: Oban,
      start: {__MODULE__, :start_link, []},
      type: :supervisor,
      restart: :permanent
    }
  end

  def start_link do
    status = classify(Mithril.Repo.query("SELECT to_regclass('public.oban_jobs')::text"))

    case start_result(status) do
      :start ->
        Oban.start_link(Application.fetch_env!(:mithril, Oban))

      {:error, :oban_schema_missing} = error ->
        Logger.error("Oban schema public.oban_jobs is missing")
        error
    end
  end

  @doc false
  def start_result(:ready), do: :start
  def start_result(:unknown), do: :start
  def start_result(:missing), do: {:error, :oban_schema_missing}

  @doc false
  def classify({:ok, %{rows: [[name]]}}) when is_binary(name) and name != "", do: :ready
  def classify({:ok, %{rows: [[nil]]}}), do: :missing
  def classify({:ok, %{rows: []}}), do: :missing
  def classify({:ok, %{rows: nil}}), do: :missing
  def classify(_result), do: :unknown
end
