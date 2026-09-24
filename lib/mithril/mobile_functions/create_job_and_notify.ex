defmodule Mithril.MobileFunctions.CreateJobAndNotify do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.MobileGateway
  alias Mithril.RateLimiter
  alias Mithril.Repo

  @radius_meters 10_000
  @offer_limit 15
  @default_offer_expires_seconds 120
  @expo_token_regex ~r/^(Expo(nent)?PushToken)\[.+\]$/
  @date_regex ~r/^\d{4}-\d{2}-\d{2}$/
  @time_regex ~r/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(customer_id, body) when is_binary(customer_id) and is_map(body) do
    with {:ok, fields} <- parse_body(body),
         :ok <- ensure_customer_role(customer_id),
         :ok <- rate_limit_create(customer_id),
         {:ok, {job_id, cleaner_ids, offers_count}} <-
           persist_job_and_offers(customer_id, fields),
         push_attempted <- send_job_offer_pushes(cleaner_ids, job_id) do
      {:ok,
       %{
         job_id: job_id,
         offers_count: offers_count,
         push_attempted: push_attempted
       }}
    end
  end

  defp parse_body(body) do
    address_text = body |> Map.get("address_text", "") |> to_string() |> String.trim()
    lat = Map.get(body, "lat")
    lng = Map.get(body, "lng")
    price = Map.get(body, "price")
    scheduled_date = body |> Map.get("scheduled_date", "") |> to_string() |> String.trim()
    start_time = body |> Map.get("start_time", "") |> to_string() |> String.trim()
    duration_hours = Map.get(body, "duration_hours")
    offer_expires_in_seconds = Map.get(body, "offer_expires_in_seconds")

    cond do
      address_text == "" or is_nil(lat) or is_nil(lng) or is_nil(price) ->
        {:error,
         {:status, 400, %{error: "Missing required fields: address_text, lat, lng, price"}}}

      scheduled_date == "" or start_time == "" or is_nil(duration_hours) ->
        {:error,
         {:status, 400,
          %{error: "Missing required fields: scheduled_date, start_time, duration_hours"}}}

      not Regex.match?(@date_regex, scheduled_date) ->
        {:error, {:status, 400, %{error: "scheduled_date must be YYYY-MM-DD"}}}

      true ->
        with {:ok, normalized_time} <- normalize_start_time(start_time),
             {:ok, duration} <- parse_duration(duration_hours),
             {:ok, lat_num, lng_num} <- parse_coordinates(lat, lng),
             {:ok, price_num} <- parse_price(price),
             :ok <- ensure_future_date(scheduled_date) do
          expires_seconds = parse_offer_expiry(offer_expires_in_seconds)
          offer_expires_at = DateTime.utc_now() |> DateTime.add(expires_seconds, :second)

          {:ok,
           %{
             address_text: address_text,
             lat: lat_num,
             lng: lng_num,
             price: price_num,
             scheduled_date: scheduled_date,
             start_time: normalized_time,
             duration_hours: duration,
             offer_expires_at: offer_expires_at
           }}
        end
    end
  end

  defp normalize_start_time(start_time) do
    case Regex.run(@time_regex, start_time) do
      [_, hour_text, minute_text] ->
        build_start_time(hour_text, minute_text, "0")

      [_, hour_text, minute_text, second_text] ->
        build_start_time(hour_text, minute_text, second_text)

      _ ->
        {:error, {:status, 400, %{error: "start_time must be HH:mm or HH:mm:ss"}}}
    end
  end

  defp build_start_time(hour_text, minute_text, second_text) do
    hour = String.to_integer(hour_text)
    minute = String.to_integer(minute_text)
    second = if second_text in [nil, ""], do: 0, else: String.to_integer(second_text)

    if hour > 23 or minute > 59 or second > 59 do
      {:error, {:status, 400, %{error: "start_time is out of range"}}}
    else
      {:ok,
       String.pad_leading(Integer.to_string(hour), 2, "0") <>
         ":" <>
         String.pad_leading(Integer.to_string(minute), 2, "0") <>
         ":" <>
         String.pad_leading(Integer.to_string(second), 2, "0")}
    end
  end

  defp parse_duration(duration_hours) do
    duration =
      case duration_hours do
        value when is_integer(value) ->
          value

        value when is_float(value) ->
          trunc(value)

        value when is_binary(value) ->
          case Integer.parse(String.trim(value)) do
            {parsed, _} -> parsed
            :error -> nil
          end

        _ ->
          nil
      end

    if is_integer(duration) and duration >= 1 and duration <= 24 do
      {:ok, duration}
    else
      {:error, {:status, 400, %{error: "duration_hours must be an integer between 1 and 24"}}}
    end
  end

  defp parse_coordinates(lat, lng) do
    lat_num = parse_number(lat)
    lng_num = parse_number(lng)

    if valid_lat_lng?(lat_num, lng_num) do
      {:ok, lat_num, lng_num}
    else
      {:error, {:status, 400, %{error: "Invalid coordinates"}}}
    end
  end

  defp parse_price(price) do
    price_num = parse_number(price)

    if is_number(price_num) and price_num >= 1 and price_num <= 50_000 do
      {:ok, price_num}
    else
      {:error, {:status, 400, %{error: "Invalid price"}}}
    end
  end

  defp ensure_future_date(scheduled_date) do
    case Date.from_iso8601(scheduled_date) do
      {:ok, date} ->
        if Date.compare(date, Date.utc_today()) == :lt do
          {:error, {:status, 400, %{error: "scheduled_date must be today or later"}}}
        else
          :ok
        end

      _ ->
        {:error, {:status, 400, %{error: "scheduled_date must be YYYY-MM-DD"}}}
    end
  end

  defp rate_limit_create(customer_id) do
    case RateLimiter.check({:create_job_and_notify, customer_id}, 5, 600_000) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        {:error, {:status, 429, %{error: "Too many jobs. Try again later."}}}
    end
  end

  defp parse_number(value) when is_integer(value), do: value * 1.0
  defp parse_number(value) when is_float(value), do: value

  defp parse_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> :nan
    end
  end

  defp parse_number(_), do: :nan

  defp valid_lat_lng?(lat, lng) when is_number(lat) and is_number(lng) do
    lat >= -90 and lat <= 90 and lng >= -180 and lng <= 180
  end

  defp valid_lat_lng?(_, _), do: false

  defp parse_offer_expiry(raw) do
    value =
      case raw do
        nil ->
          @default_offer_expires_seconds

        n when is_integer(n) ->
          n

        n when is_float(n) ->
          trunc(n)

        n when is_binary(n) ->
          case Integer.parse(String.trim(n)) do
            {parsed, _} -> parsed
            :error -> @default_offer_expires_seconds
          end

        _ ->
          @default_offer_expires_seconds
      end

    value |> max(30) |> min(3600)
  end

  defp ensure_customer_role(customer_id) do
    case MobileGateway.call_rpc(customer_id, "get_user_role", %{"p_user_id" => customer_id}) do
      {:ok, role_payload} ->
        roles = roles_from_payload(role_payload)

        if "customer" in roles do
          :ok
        else
          {:error, {:status, 403, %{error: "Only customers can create jobs"}}}
        end

      {:error, _} ->
        {:error, {:status, 500, %{error: "Could not verify user role"}}}
    end
  end

  defp roles_from_payload(%{"roles" => roles}) when is_list(roles), do: roles
  defp roles_from_payload(%{roles: roles}) when is_list(roles), do: roles

  defp roles_from_payload(payload) when is_map(payload) do
    case Map.get(payload, "roles") || Map.get(payload, :roles) do
      roles when is_list(roles) -> roles
      _ -> []
    end
  end

  defp roles_from_payload(_), do: []

  defp persist_job_and_offers(customer_id, fields) do
    case Repo.transaction(fn ->
           with {:ok, job_id} <- insert_job(customer_id, fields),
                {:ok, cleaner_ids} <- nearby_cleaner_ids(fields),
                {:ok, offers_count} <- insert_offers(job_id, cleaner_ids) do
             {job_id, cleaner_ids, offers_count}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:status, _, _} = reason} ->
        {:error, reason}

      {:error, _} ->
        {:error, {:status, 500, %{error: "Could not create job"}}}
    end
  end

  defp insert_job(customer_id, fields) do
    sql = """
    INSERT INTO public.jobs (
      customer_id, address_text, lat, lng, price, status, offer_expires_at
    ) VALUES (
      $1::uuid, $2, $3, $4, $5, 'pending', $6::timestamptz
    )
    RETURNING id
    """

    case Repo.query(sql, [
           DbUuid.dump!(customer_id),
           fields.address_text,
           fields.lat,
           fields.lng,
           fields.price,
           DateTime.to_iso8601(fields.offer_expires_at)
         ]) do
      {:ok, %{rows: [[job_id]]}} ->
        {:ok, DbUuid.encode(job_id)}

      {:error, _} ->
        {:error, {:status, 500, %{error: "Could not create job"}}}
    end
  end

  defp nearby_cleaner_ids(fields) do
    sql = """
    SELECT id
    FROM public.get_nearby_available_cleaners($1, $2, $3, $4::date, $5::time, $6)
    """

    case Repo.query(sql, [
           fields.lat,
           fields.lng,
           @radius_meters,
           fields.scheduled_date,
           fields.start_time,
           fields.duration_hours
         ]) do
      {:ok, %{rows: rows}} ->
        ids =
          rows
          |> Enum.map(fn [id] -> id end)
          |> Enum.uniq()
          |> Enum.take(@offer_limit)

        {:ok, ids}

      {:error, _} ->
        {:error, {:status, 500, %{error: "Could not find nearby cleaners"}}}
    end
  end

  defp insert_offers(_job_id, []), do: {:ok, 0}

  defp insert_offers(job_id, cleaner_ids) do
    Enum.reduce_while(cleaner_ids, {:ok, 0}, fn cleaner_id, {:ok, count} ->
      case Repo.query(
             """
             INSERT INTO public.job_offers (job_id, cleaner_id, status)
             VALUES ($1::uuid, $2::uuid, 'sent')
             """,
             [DbUuid.dump!(job_id), DbUuid.dump!(cleaner_id)]
           ) do
        {:ok, _} ->
          {:cont, {:ok, count + 1}}

        {:error, _} ->
          {:halt, {:error, {:status, 500, %{error: "Could not create job offers"}}}}
      end
    end)
  end

  defp send_job_offer_pushes([], _job_id), do: 0

  defp send_job_offer_pushes(cleaner_ids, job_id) do
    targets = load_push_targets(cleaner_ids)
    screen_path = "/(modal)/job-claim?jobId=#{job_id}"

    if targets == [] do
      0
    else
      messages =
        Enum.map(targets, fn token ->
          %{
            to: token,
            title: "New cleaning job near you",
            body: "Tap to claim and view details",
            sound: "default",
            priority: "high",
            channelId: "job_offers",
            data: %{
              type: "job_offer",
              jobId: job_id,
              screen: screen_path,
              audience: "cleaner"
            }
          }
        end)

      _ = Req.post("https://exp.host/--/api/v2/push/send", json: messages)
      length(targets)
    end
  end

  defp load_push_targets(cleaner_ids) do
    sql = """
    SELECT DISTINCT token
    FROM (
      SELECT expo_push_token AS token
      FROM public.cleaner_devices
      WHERE cleaner_id = ANY($1::uuid[]) AND expo_push_token IS NOT NULL
      UNION ALL
      SELECT token
      FROM public.device_tokens
      WHERE user_id = ANY($1::uuid[]) AND token IS NOT NULL
    ) tokens
    """

    case Repo.query(sql, [DbUuid.dump_all!(cleaner_ids)]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [token] -> token end)
        |> Enum.filter(&expo_token?/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp expo_token?(token) when is_binary(token), do: Regex.match?(@expo_token_regex, token)
  defp expo_token?(_), do: false
end
