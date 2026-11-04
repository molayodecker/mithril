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
    case classify(Mithril.Repo.query("SELECT to_regclass('public.oban_jobs')::text")) do
      :ready ->
        Oban.start_link(Application.fetch_env!(:mithril, Oban))

      :missing ->
        Logger.error("Oban schema public.oban_jobs is missing; scheduled jobs will not run")
        :ignore

      :unknown ->
        Oban.start_link(Application.fetch_env!(:mithril, Oban))
    end
  end

  @doc false
  def classify({:ok, %{rows: [[name]]}}) when is_binary(name) and name != "", do: :ready
  def classify({:ok, %{rows: [[nil]]}}), do: :missing
  def classify({:ok, %{rows: []}}), do: :missing
  def classify({:ok, %{rows: nil}}), do: :missing
  def classify(_result), do: :unknown
end
