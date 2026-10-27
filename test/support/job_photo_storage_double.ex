defmodule Mithril.JobPhotoStorage.TestDouble do
  @moduledoc false

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @spec reset!() :: :ok
  def reset! do
    Agent.update(__MODULE__, fn _ -> [] end)
  end

  @spec uploads() :: [{String.t(), binary(), String.t()}]
  def uploads do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end

  @spec put_job_photo(String.t(), binary(), String.t()) :: {:ok, String.t()}
  def put_job_photo(object_key, body, content_type) do
    Agent.update(__MODULE__, fn uploads ->
      [{object_key, body, content_type} | uploads]
    end)

    {:ok, object_key}
  end

  @spec delete_job_photo(String.t()) :: :ok
  def delete_job_photo(object_key) do
    Agent.update(__MODULE__, fn uploads ->
      [{object_key, "", "delete"} | uploads]
    end)

    :ok
  end
end
