defmodule Mithril.Sumsub.Applicant do
  @moduledoc false

  alias Mithril.Sumsub.Client
  alias Mithril.Sumsub.Config

  @exists_regex ~r/already exists[^0-9a-f]*([0-9a-f]{24})/i

  @spec ensure_for_user(map()) :: %{applicant_id: String.t() | nil, created: boolean()}
  def ensure_for_user(input) when is_map(input) do
    external_user_id = input |> Map.get(:external_user_id, "") |> to_string() |> String.trim()

    if external_user_id == "" do
      %{applicant_id: nil, created: false}
    else
      payload =
        %{
          "externalUserId" => external_user_id,
          "email" => optional_string(Map.get(input, :email)),
          "phone" => optional_string(Map.get(input, :phone)),
          "info" => %{
            "firstName" => optional_string(Map.get(input, :first_name)),
            "lastName" => optional_string(Map.get(input, :last_name)),
            "dob" => optional_string(Map.get(input, :dob)),
            "type" => "individual",
            "country" => Config.country_code(),
            "nationality" => Config.nationality_code()
          }
        }
        |> drop_nil_values()

      path =
        "/resources/applicants?levelName=#{URI.encode(Config.level_name())}"

      case Client.post(path, payload) do
        {:ok, body} ->
          applicant_id = read_applicant_id(body) || find_by_external_user_id(external_user_id)
          %{applicant_id: applicant_id, created: applicant_id != nil}

        {:error, {:status, _status, details}} ->
          inline_id = extract_applicant_id_from_exists_error(details)
          applicant_id = inline_id || find_by_external_user_id(external_user_id)
          %{applicant_id: applicant_id, created: false}
      end
    end
  end

  @spec find_by_external_user_id(String.t()) :: String.t() | nil
  def find_by_external_user_id(external_user_id) when is_binary(external_user_id) do
    path =
      "/resources/applicants/-;externalUserId=#{URI.encode(String.trim(external_user_id))}"

    case Client.get(path) do
      {:ok, body} -> read_applicant_id(body)
      _ -> nil
    end
  end

  defp read_applicant_id(body) when is_map(body) do
    id =
      case Map.get(body, "id") do
        value when is_binary(value) ->
          value

        _ ->
          applicant = Map.get(body, "applicant") || %{}

          case Map.get(applicant, "id") do
            nested when is_binary(nested) -> nested
            _ -> nil
          end
      end

    if is_binary(id) and String.trim(id) != "", do: String.trim(id), else: nil
  end

  defp extract_applicant_id_from_exists_error(text) when is_binary(text) do
    case Regex.run(@exists_regex, text) do
      [_, applicant_id] -> applicant_id
      _ -> nil
    end
  end

  defp extract_applicant_id_from_exists_error(_), do: nil

  defp optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_string(_), do: nil

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
