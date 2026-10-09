defmodule Mithril.DirectAdminPromotions do
  @moduledoc "Staff promo code catalog with redemption counts."

  require Logger

  alias Mithril.Auth
  alias Mithril.Repo

  def list_codes(user_id) do
    with {:ok, uid} <- dump_uuid(user_id),
         :ok <- require_staff(uid) do
      case Repo.query("""
           SELECT jsonb_build_object(
             'id', pc.id,
             'code', pc.code::text,
             'active', pc.active,
             'maxRedemptions', pc.max_redemptions,
             'createdAt', pc.created_at,
             'promotionId', p.id,
             'promotionSlug', p.slug,
             'promotionType', p.type,
             'promotionValue', p.value,
             'headline', p.headline,
             'termsMarkdown', p.terms_markdown,
             'promotionActive', p.active,
             'validFrom', p.valid_from,
             'validTo', p.valid_to,
             'promotionMaxRedemptions', p.max_redemptions,
             'redemptionCount', COALESCE(stats.redemption_count, 0),
             'status', CASE
               WHEN NOT p.active OR NOT pc.active THEN 'inactive'
               WHEN p.valid_from IS NOT NULL AND p.valid_from > timezone('utc', now()) THEN 'scheduled'
               WHEN p.valid_to IS NOT NULL AND p.valid_to < timezone('utc', now()) THEN 'expired'
               ELSE 'active'
             END
           )
           FROM public.promotion_codes pc
           JOIN public.promotions p ON p.id = pc.promotion_id
           LEFT JOIN LATERAL (
             SELECT count(*)::integer AS redemption_count
             FROM public.promotion_redemptions r
             WHERE r.promotion_id = p.id
               AND r.status IN ('reserved', 'redeemed')
           ) stats ON true
           ORDER BY pc.created_at DESC
           LIMIT 200
           """) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &first_row/1)}
        {:error, error} -> database_error(error)
      end
    else
      :error -> {:error, :invalid_user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_staff(uid) do
    if Auth.staff_uuid?(uid), do: :ok, else: {:error, :forbidden}
  end

  defp dump_uuid(value) when is_binary(value), do: Ecto.UUID.dump(value)
  defp dump_uuid(_), do: :error

  defp first_row([row]), do: row
  defp first_row(row) when is_map(row), do: row

  defp database_error(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, :missing_table}
  end

  defp database_error(error) do
    Logger.error("Direct admin promotions database error: #{inspect(error)}")
    {:error, :database_unavailable}
  end
end
