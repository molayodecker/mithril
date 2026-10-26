defmodule Mithril.PaystackCustomers do
  @moduledoc false

  require Logger

  alias Mithril.DbUuid
  alias Mithril.Paystack
  alias Mithril.Repo

  @spec ensure(map()) :: :ok | {:error, term()}
  def ensure(payload) when is_map(payload) do
    user_id = text(payload, "user_id")

    cond do
      not is_binary(user_id) ->
        :ok

      true ->
        case load_cleaner(user_id) do
          {:ok, %{customer_code: code}} when is_binary(code) and code != "" ->
            :ok

          {:ok, cleaner} ->
            create_and_store(cleaner)

          :missing ->
            :ok
        end
    end
  end

  defp create_and_store(cleaner) do
    if cleaner.email == nil do
      {:error, :missing_email}
    else
      case Paystack.create_customer(%{
             email: cleaner.email,
             first_name: cleaner.first_name,
             last_name: cleaner.last_name,
             phone: cleaner.phone
           }) do
        {:ok, %{customer_code: customer_code}}
        when is_binary(customer_code) and customer_code != "" ->
          store_customer_code(cleaner.user_id, customer_code)

        {:ok, _} ->
          {:error, :paystack_customer_missing_code}

        {:error, :payment_not_configured} ->
          {:error, :payment_not_configured}

        {:error, :missing_email} ->
          {:error, :missing_email}

        {:error, reason} ->
          Logger.warning("paystack customer create failed: #{inspect(reason)}")
          {:error, :paystack_customer_failed}
      end
    end
  end

  defp store_customer_code(user_id, customer_code) do
    case Repo.query(
           """
           UPDATE public.cleaner_data
           SET paystack_customer_id = $2,
               updated_at = now()
           WHERE user_id = $1::uuid
             AND (paystack_customer_id IS NULL OR btrim(paystack_customer_id) = '')
           """,
           [DbUuid.dump!(user_id), customer_code]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_cleaner(user_id) do
    case Repo.query(
           """
           SELECT u.id::text,
                  nullif(btrim(u.email), ''),
                  nullif(btrim(u.phone), ''),
                  nullif(btrim(cd.paystack_customer_id), ''),
                  nullif(btrim(p.firstname), ''),
                  nullif(btrim(p.lastname), '')
           FROM public.users u
           JOIN public.cleaner_data cd ON cd.user_id = u.id
           LEFT JOIN public.profiles p ON p.id = u.id
           WHERE u.id = $1::uuid
           """,
           [DbUuid.dump!(user_id)]
         ) do
      {:ok, %{rows: [[id, email, phone, customer_code, first_name, last_name]]}} ->
        {:ok,
         %{
           user_id: id,
           email: email,
           phone: phone,
           customer_code: customer_code,
           first_name: first_name,
           last_name: last_name
         }}

      _ ->
        :missing
    end
  end

  defp text(map, key) do
    value = Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
    if is_binary(value) and String.trim(value) != "", do: String.trim(value), else: nil
  rescue
    ArgumentError -> nil
  end
end
