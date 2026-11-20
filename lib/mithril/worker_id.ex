defmodule Mithril.WorkerId do
  @moduledoc """
  Public Worker ID card.

  A scan shows this card: name, profile photo, role, public ID, and whether
  the worker is active. Cleared comes from the Sumsub review. Suspended comes
  from the worker or account status. Government ID images, document numbers,
  and Sumsub applicant ids are never returned.
  """

  alias Mithril.DbUuid
  alias Mithril.Repo

  require Logger

  @verify_origin "https://worker.tryinstaclean.com"
  @slug_re ~r/^[23456789abcdefghjkmnpqrstuvwxyz]{8}$/
  @roles %{
    "cleaning" => "Residential Cleaner",
    "washing" => "Laundry",
    "ironing" => "Ironing",
    "dry_cleaning" => "Dry cleaning",
    "fold_clothes" => "Laundry",
    "dish_washing" => "Kitchen",
    "shoe_cleaning" => "Shoe cleaning"
  }

  @type worker_record :: %{
          user_id: binary(),
          slug: String.t(),
          card: map(),
          void_pass: boolean()
        }

  @spec public_card(term()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def public_card(code) do
    with {:ok, slug} <- normalize_code(code),
         {:ok, record} <- fetch_by_slug(slug) do
      {:ok, record.card}
    else
      {:error, :invalid_code} -> {:error, :not_found}
      other -> other
    end
  end

  @spec for_user(term()) :: {:ok, map()} | {:error, term()}
  def for_user(user_id) do
    case load_user(user_id) do
      {:ok, record} ->
        {:ok, record.card}

      {:error, :not_found} ->
        {:error,
         {:status, 404,
          %{error: "not_found", message: "Could not load your worker ID. Try again."}}}

      {:error, :invalid_user} ->
        {:error,
         {:status, 400, %{error: "invalid_user", message: "Sign in to view your worker ID."}}}

      {:error, :unavailable} ->
        {:error,
         {:status, 500,
          %{error: "worker_id_unavailable", message: "Could not load your worker ID. Try again."}}}
    end
  end

  @spec load_user(term()) ::
          {:ok, worker_record()} | {:error, :not_found | :invalid_user | :unavailable}
  def load_user(user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> fetch_by_user(DbUuid.dump!(uuid))
      :error -> {:error, :invalid_user}
    end
  end

  def load_user(_user_id), do: {:error, :invalid_user}

  @spec presentation(map()) :: map()
  def presentation(row) when is_map(row) do
    cleaner_status = text(row[:cleaner_status] || row["cleaner_status"])
    user_status = text(row[:user_status] || row["user_status"])
    review = text(row[:review_answer] || row["review_answer"]) |> String.upcase()
    kyc = text(row[:kyc_status] || row["kyc_status"]) |> String.downcase()
    suspended = cleaner_status == "suspended" or user_status == "suspended"
    inactive = cleaner_status == "inactive" or user_status == "inactive"
    cleared = review == "GREEN" or kyc in ["verified", "approved"]

    active =
      not suspended and not inactive and cleaner_status == "active" and
        user_status in ["", "active"] and cleared

    label =
      cond do
        suspended -> "Suspended"
        inactive -> "Inactive"
        active -> "Active"
        true -> "Pending"
      end

    %{
      active: active,
      background_cleared: cleared,
      status_label: label,
      void_pass: suspended
    }
  end

  @spec card_from_row(map()) :: map()
  def card_from_row(row) when is_map(row) do
    slug = text(row[:slug] || row["slug"])
    view = presentation(row)

    %{
      "name" => display_name(row[:name] || row["name"]),
      "role" => role_label(row[:categories] || row["categories"]),
      "idNumber" => id_number(slug),
      "memberSince" => member_since(row[:created_at] || row["created_at"]),
      "backgroundCleared" => view.background_cleared,
      "active" => view.active,
      "statusLabel" => view.status_label,
      "verifyUrl" => verify_url(slug),
      "photoUrl" => public_photo(row[:photo_url] || row["photo_url"])
    }
  end

  @spec verify_url(String.t()) :: String.t()
  def verify_url(slug) when is_binary(slug), do: "#{@verify_origin}/id/#{slug}"

  @spec id_number(String.t()) :: String.t()
  def id_number(slug) when is_binary(slug), do: "IC-" <> String.upcase(slug)

  defp fetch_by_slug(slug) do
    query("WHERE lower(cd.booking_slug) = $1", [slug])
  end

  defp fetch_by_user(user_id) do
    query("WHERE cd.user_id = $1::uuid", [user_id])
  end

  defp query(where, params) do
    sql = """
    SELECT
      cd.user_id,
      lower(cd.booking_slug),
      cd.status::text,
      u.status::text,
      cd.service_categories,
      COALESCE(
        NULLIF(btrim(p.fullname), ''),
        NULLIF(btrim(concat_ws(' ', p.firstname, p.lastname)), '')
      ),
      p.avatar_url,
      u.created_at,
      k.review_answer,
      k.kyc_status
    FROM public.cleaner_data cd
    JOIN public.users u ON u.id = cd.user_id
    LEFT JOIN public.profiles p ON p.id = cd.user_id
    LEFT JOIN LATERAL (
      SELECT review_answer, kyc_status
      FROM public.kyc_profiles
      WHERE user_id = cd.user_id
      ORDER BY updated_at DESC NULLS LAST
      LIMIT 1
    ) k ON true
    #{where}
    LIMIT 1
    """

    case Repo.query(sql, params) do
      {:ok, %{rows: [row]}} ->
        {:ok, record_from_db(row)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:error, :unavailable}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_column}}} ->
        {:error, :unavailable}

      {:error, error} ->
        Logger.error("worker id lookup failed: #{Exception.message(error)}")
        {:error, :unavailable}
    end
  end

  defp record_from_db([
         user_id,
         slug,
         cleaner_status,
         user_status,
         categories,
         name,
         photo_url,
         created_at,
         review_answer,
         kyc_status
       ]) do
    row = %{
      slug: slug,
      cleaner_status: cleaner_status,
      user_status: user_status,
      categories: categories,
      name: name,
      photo_url: photo_url,
      created_at: created_at,
      review_answer: review_answer,
      kyc_status: kyc_status
    }

    view = presentation(row)

    %{
      user_id: user_id,
      slug: slug,
      card: card_from_row(row),
      void_pass: view.void_pass
    }
  end

  defp normalize_code(code) when is_binary(code) do
    slug = code |> String.trim() |> String.downcase()
    if Regex.match?(@slug_re, slug), do: {:ok, slug}, else: {:error, :invalid_code}
  end

  defp normalize_code(_code), do: {:error, :invalid_code}

  @spec role_label(term()) :: String.t()
  def role_label(categories) do
    category =
      categories
      |> category_list()
      |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)

    case category do
      nil ->
        "Worker"

      value ->
        key = value |> String.trim() |> String.downcase()
        Map.get(@roles, key, String.replace(key, "_", " "))
    end
  end

  defp category_list(value) when is_list(value), do: value

  defp category_list("{" <> rest) do
    rest
    |> String.trim_trailing("}")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim(&1, "\""))
  end

  defp category_list(_value), do: []

  defp display_name(name) do
    trimmed = text(name)
    if trimmed == "", do: "Instaclean worker", else: trimmed
  end

  defp member_since(%DateTime{} = created), do: Calendar.strftime(created, "%b %Y")
  defp member_since(%NaiveDateTime{} = created), do: Calendar.strftime(created, "%b %Y")
  defp member_since(_created), do: nil

  defp public_photo(url) when is_binary(url) do
    trimmed = String.trim(url)
    if String.starts_with?(trimmed, "https://"), do: trimmed, else: nil
  end

  defp public_photo(_url), do: nil

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
