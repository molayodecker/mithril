defmodule Mithril.R2Storage do
  @moduledoc """
  Private Cloudflare R2 objects using S3 Signature V4.
  """

  @region "auto"
  @service "s3"

  def put(key, bytes, content_type) when is_binary(bytes) do
    request(:put, key, bytes, content_type)
  end

  def delete(key), do: request(:delete, key, "", nil)

  def signed_url(key, expires_seconds \\ 3600)

  def signed_url(key, expires_seconds) when is_binary(key) and expires_seconds in 1..604_800 do
    with {:ok, config} <- config() do
      now = DateTime.utc_now()
      stamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      date = String.slice(stamp, 0, 8)
      scope = "#{date}/#{@region}/#{@service}/aws4_request"
      credential = "#{config.access_key}/#{scope}"
      host = "#{config.account_id}.r2.cloudflarestorage.com"
      uri = object_uri(config.bucket, key)

      query =
        [
          {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
          {"X-Amz-Credential", credential},
          {"X-Amz-Date", stamp},
          {"X-Amz-Expires", Integer.to_string(expires_seconds)},
          {"X-Amz-SignedHeaders", "host"}
        ]
        |> canonical_query()

      canonical = "GET\n#{uri}\n#{query}\nhost:#{host}\n\nhost\nUNSIGNED-PAYLOAD"
      signature = sign(config.secret_key, date, stamp, scope, canonical)
      {:ok, "https://#{host}#{uri}?#{query}&X-Amz-Signature=#{signature}"}
    end
  end

  def signed_url(_, _), do: {:error, :invalid_expiry}

  defp request(method, key, bytes, content_type) do
    with {:ok, config} <- config() do
      now = DateTime.utc_now()
      stamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      date = String.slice(stamp, 0, 8)
      scope = "#{date}/#{@region}/#{@service}/aws4_request"
      host = "#{config.account_id}.r2.cloudflarestorage.com"
      uri = object_uri(config.bucket, key)
      hash = sha256(bytes)
      verb = method |> Atom.to_string() |> String.upcase()
      type_headers = if content_type, do: [{"content-type", content_type}], else: []

      signed_headers =
        [
          {"host", host},
          {"x-amz-content-sha256", hash},
          {"x-amz-date", stamp}
        ] ++ type_headers

      sorted = Enum.sort_by(signed_headers, &elem(&1, 0))
      header_names = Enum.map_join(sorted, ";", &elem(&1, 0))
      header_lines = Enum.map_join(sorted, "", fn {k, v} -> "#{k}:#{v}\n" end)
      canonical = "#{verb}\n#{uri}\n\n#{header_lines}\n#{header_names}\n#{hash}"
      signature = sign(config.secret_key, date, stamp, scope, canonical)

      authorization =
        "AWS4-HMAC-SHA256 Credential=#{config.access_key}/#{scope}, SignedHeaders=#{header_names}, Signature=#{signature}"

      case Req.request(
             method: method,
             url: "https://#{host}#{uri}",
             body: bytes,
             headers: sorted ++ [{"authorization", authorization}],
             receive_timeout: 30_000,
             retry: false
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _ -> {:error, :storage_unavailable}
      end
    end
  end

  defp config do
    values = %{
      account_id: System.get_env("R2_ACCOUNT_ID"),
      bucket: System.get_env("R2_BUCKET", "instaclean-media"),
      access_key: System.get_env("R2_ACCESS_KEY_ID"),
      secret_key: System.get_env("R2_SECRET_ACCESS_KEY")
    }

    if Enum.all?(Map.values(values), &(is_binary(&1) and byte_size(&1) > 0)) and
         Regex.match?(~r/^[a-zA-Z0-9_-]+$/, values.account_id) and
         Regex.match?(~r/^[a-zA-Z0-9._-]+$/, values.bucket) do
      {:ok, values}
    else
      {:error, :storage_not_configured}
    end
  end

  defp object_uri(bucket, key) do
    encoded =
      Enum.map_join([bucket | String.split(key, "/")], "/", fn part ->
        URI.encode(part, &URI.char_unreserved?/1)
      end)

    "/" <> encoded
  end

  defp canonical_query(pairs) do
    pairs
    |> Enum.map(fn {k, v} ->
      {URI.encode(k, &URI.char_unreserved?/1), URI.encode(v, &URI.char_unreserved?/1)}
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp sign(secret, date, stamp, scope, canonical) do
    key =
      ("AWS4" <> secret)
      |> hmac(date)
      |> hmac(@region)
      |> hmac(@service)
      |> hmac("aws4_request")

    string_to_sign = "AWS4-HMAC-SHA256\n#{stamp}\n#{scope}\n#{sha256(canonical)}"
    hmac(key, string_to_sign) |> Base.encode16(case: :lower)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
