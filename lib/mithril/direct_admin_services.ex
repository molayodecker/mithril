defmodule Mithril.DirectAdminServices do
  @moduledoc "Staff catalog: list and update service_types pricing and visibility."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  def list(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_staff(uid) do
      case Repo.query("""
           SELECT #{service_json_select()}
           FROM public.service_types st
           LEFT JOIN public.service_categories sc ON sc.id = st.category_id
           ORDER BY COALESCE(st.weight, 0) ASC, st.name ASC
           """) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &first_row/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def get(user_id, service_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_staff(uid),
         {:ok, sid} <- positive_integer(service_id) do
      case Repo.query(
             """
             SELECT #{service_json_select()}
             FROM public.service_types st
             LEFT JOIN public.service_categories sc ON sc.id = st.category_id
             WHERE st.id = $1
             LIMIT 1
             """,
             [sid]
           ) do
        {:ok, %{rows: [[service]]}} -> {:ok, service}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def update(user_id, service_id, params) when is_map(params) do
    with {:ok, _uid} <- dump_uuid(user_id),
         :ok <- require_admin_user(user_id),
         {:ok, sid} <- positive_integer(service_id),
         {:ok, patch} <- validate_update(params),
         {:ok, _} <-
           Repo.query(
             """
             UPDATE public.service_types
             SET
               name = COALESCE($2, name),
               price = COALESCE($3, price),
               active = COALESCE($4, active),
               description = COALESCE($5, description),
               minimum_duration_hours = COALESCE($6, minimum_duration_hours),
               maximum_duration_hours = COALESCE($7, maximum_duration_hours),
               last_updated = timezone('utc', now())
             WHERE id = $1
             """,
             [
               sid,
               patch.name,
               patch.price,
               patch.active,
               patch.description,
               patch.minimum_duration_hours,
               patch.maximum_duration_hours
             ]
           ) do
      fetch_after_update(sid)
    else
      :error -> {:error, :invalid_request}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, error} -> database_error(error)
    end
  end

  defp fetch_after_update(sid) do
    case Repo.query(
           """
           SELECT #{service_json_select()}
           FROM public.service_types st
           LEFT JOIN public.service_categories sc ON sc.id = st.category_id
           WHERE st.id = $1
           LIMIT 1
           """,
           [sid]
         ) do
      {:ok, %{rows: [[service]]}} -> {:ok, service}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, error} -> database_error(error)
    end
  end

  defp service_json_select do
    """
    jsonb_build_object(
      'id', st.id,
      'name', st.name,
      'categoryId', st.category_id,
      'categoryName', sc.name,
      'categorySlug', sc.slug,
      'description', st.description,
      'features', COALESCE(to_jsonb(st.features), '[]'::jsonb),
      'priceGhs', st.price,
      'active', COALESCE(st.active, true),
      'minimumDurationHours', COALESCE(st.minimum_duration_hours, 2),
      'maximumDurationHours', COALESCE(st.maximum_duration_hours, 12),
      'durationIncrementHours', COALESCE(st.duration_increment_hours, 0.5),
      'specialtySlug', st.specialty_slug,
      'weight', COALESCE(st.weight, 0),
      'lastUpdated', st.last_updated
    )
    """
  end

  defp validate_update(params) do
    with {:ok, name} <- optional_text(param(params, "name"), 120),
         {:ok, description} <- optional_text(param(params, "description"), 2000),
         {:ok, active} <- optional_bool(param(params, "active")),
         {:ok, price} <- optional_price(param(params, "priceGhs")),
         {:ok, min_hours} <- optional_hours(param(params, "minimumDurationHours")),
         {:ok, max_hours} <- optional_hours(param(params, "maximumDurationHours")) do
      patch = %{
        name: name,
        description: description,
        active: active,
        price: price,
        minimum_duration_hours: min_hours,
        maximum_duration_hours: max_hours
      }

      if Enum.all?(patch, fn {_k, v} -> is_nil(v) end) do
        {:error, :invalid_request}
      else
        {:ok, patch}
      end
    else
      :invalid -> {:error, :invalid_request}
    end
  end

  defp param(params, key) when is_map(params) do
    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, String.to_atom(key)) -> Map.get(params, String.to_atom(key))
      true -> nil
    end
  end

  defp optional_text(nil, _), do: {:ok, nil}
  defp optional_text("", _), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:ok, nil}, else: {:ok, String.slice(value, 0, max)}
  end

  defp optional_text(_, _), do: :invalid

  defp optional_bool(nil), do: {:ok, nil}
  defp optional_bool(value) when is_boolean(value), do: {:ok, value}
  defp optional_bool("true"), do: {:ok, true}
  defp optional_bool("false"), do: {:ok, false}
  defp optional_bool(_), do: :invalid

  defp optional_price(nil), do: {:ok, nil}

  defp optional_price(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_price(value) when is_float(value) and value >= 0, do: {:ok, value}

  defp optional_price(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} ->
        if Decimal.compare(decimal, Decimal.new(0)) in [:gt, :eq],
          do: {:ok, decimal},
          else: :invalid

      _ ->
        :invalid
    end
  end

  defp optional_price(_), do: :invalid

  defp optional_hours(nil), do: {:ok, nil}

  defp optional_hours(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp optional_hours(value) when is_float(value) and value > 0, do: {:ok, value}

  defp optional_hours(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {hours, ""} when hours > 0 -> {:ok, hours}
      _ -> :invalid
    end
  end

  defp optional_hours(_), do: :invalid

  defp require_staff(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp require_admin_user(user_id) when is_binary(user_id) do
    if Auth.admin?(user_id), do: :ok, else: {:error, :forbidden}
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_request}
    end
  end

  defp positive_integer(_), do: {:error, :invalid_request}

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp first_row([row]), do: row
  defp first_row(row) when is_map(row), do: row

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_column}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin services database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
