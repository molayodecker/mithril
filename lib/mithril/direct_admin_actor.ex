defmodule Mithril.DirectAdminActor do
  @moduledoc false

  alias Mithril.Repo

  @doc """
  Runs `fun` in a transaction whose `mithril.actor_id` is the authenticated user.

  Security-definer writers reject a recorded-by UUID that does not match this value.
  """
  def with_actor(actor_uid, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      case Repo.query("SELECT set_config('mithril.actor_id', $1, true)", [uuid_text(actor_uid)]) do
        {:ok, _} -> fun.()
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp uuid_text(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.load!(value)
    end
  end
end
