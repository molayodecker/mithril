defmodule Mithril.Sumsub.CleanerApplicationLookup do
  @moduledoc false

  alias Mithril.Repo

  @select_fields """
  id, user_id, phone, email, sumsub_applicant_id, sumsub_external_user_id, created_at
  """

  @spec find_latest(map()) :: {:ok, map()} | {:error, :not_found} | {:error, term()}
  def find_latest(%{user_id: user_id}) when is_binary(user_id) do
    user_id = String.trim(user_id)

    if user_id == "" do
      {:error, :not_found}
    else
      sql = """
      SELECT #{@select_fields}
      FROM public.cleaner_applications
      WHERE user_id = $1::uuid
      ORDER BY created_at DESC
      LIMIT 1
      """

      case Repo.query(sql, [user_id]) do
        {:ok, %{columns: columns, rows: [row]}} ->
          {:ok, Map.new(Enum.zip(columns, row))}

        {:ok, %{rows: []}} ->
          {:error, :not_found}

        {:error, error} ->
          {:error, error}
      end
    end
  end
end
