defmodule Mithril.DirectAdminAppUpdatePolicy do
  @moduledoc "Staff control of mobile store update gates."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  @channels ~w(production preview)
  @version_re ~r/^[0-9]+\.[0-9]+\.[0-9]+$/

  def list(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid) do
      case Repo.query("""
             SELECT jsonb_build_object(
               'channel', channel,
               'minVersion', min_version,
               'recommendedVersion', recommended_version,
               'requiredMessage', required_message,
               'recommendedMessage', recommended_message,
               'updatedAt', updated_at
             )
             FROM public.app_update_policy
             WHERE channel IN ('production', 'preview')
             ORDER BY channel ASC
             """) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &hd/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  def save(user_id, params) when is_map(params) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_admin(uid),
         {:ok, input} <- validate_save(params) do
      case Repo.query(
             """
             UPDATE public.app_update_policy
             SET
               min_version = $2,
               recommended_version = $3,
               required_message = $4,
               recommended_message = $5,
               updated_at = timezone('utc', now())
             WHERE channel = $1
             RETURNING jsonb_build_object(
               'channel', channel,
               'minVersion', min_version,
               'recommendedVersion', recommended_version,
               'requiredMessage', required_message,
               'recommendedMessage', recommended_message,
               'updatedAt', updated_at
             )
             """,
             [
               input.channel,
               input.min_version,
               input.recommended_version,
               input.required_message,
               input.recommended_message
             ]
           ) do
        {:ok, %{rows: [[policy]]}} -> {:ok, policy}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_save(params) do
    channel = params["channel"] || params[:channel]
    min_version = params["minVersion"] || params[:minVersion]
    required_message = params["requiredMessage"] || params[:requiredMessage]

    with true <- channel in @channels,
         {:ok, min_version} <- required_version(min_version),
         {:ok, recommended_version} <-
           optional_version(params["recommendedVersion"] || params[:recommendedVersion]),
         {:ok, required_message} <- required_text(required_message, 500),
         {:ok, recommended_message} <-
           optional_text(params["recommendedMessage"] || params[:recommendedMessage], 500) do
      {:ok,
       %{
         channel: channel,
         min_version: min_version,
         recommended_version: normalize_recommended(min_version, recommended_version),
         required_message: required_message,
         recommended_message: recommended_message
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp required_version(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@version_re, value) do
      {:ok, value}
    else
      {:error, :invalid_request}
    end
  end

  defp required_version(_), do: {:error, :invalid_request}

  defp optional_version(nil), do: {:ok, nil}
  defp optional_version(""), do: {:ok, nil}

  defp optional_version(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, nil}
      Regex.match?(@version_re, value) -> {:ok, value}
      true -> {:error, :invalid_request}
    end
  end

  defp optional_version(_), do: {:error, :invalid_request}

  defp normalize_recommended(_min, nil), do: nil

  defp normalize_recommended(min_version, recommended_version) do
    if version_less_than?(min_version, recommended_version), do: recommended_version, else: nil
  end

  defp version_less_than?(left, right) do
    with {:ok, left_parts} <- parse_version(left),
         {:ok, right_parts} <- parse_version(right) do
      left_parts < right_parts
    else
      _ -> false
    end
  end

  defp parse_version(version) do
    case String.split(version, ".") do
      [major, minor, patch] ->
        with {major, ""} <- Integer.parse(major),
             {minor, ""} <- Integer.parse(minor),
             {patch, ""} <- Integer.parse(patch) do
          {:ok, {major, minor, patch}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp required_text(value, max) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, :invalid_request}
    else
      {:ok, String.slice(value, 0, max)}
    end
  end

  defp required_text(_, _), do: {:error, :invalid_request}

  defp optional_text(nil, _), do: {:ok, nil}
  defp optional_text("", _), do: {:ok, nil}

  defp optional_text(value, max) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:ok, nil}, else: {:ok, String.slice(value, 0, max)}
  end

  defp optional_text(_, _), do: {:error, :invalid_request}

  defp require_admin(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin app update policy database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
