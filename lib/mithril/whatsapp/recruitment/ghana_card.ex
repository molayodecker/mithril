defmodule Mithril.WhatsApp.Recruitment.GhanaCard do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.WhatsApp.Recruitment.Leads
  alias Mithril.WhatsApp.Recruitment.Storage

  def upload_page_path, do: "/join-as-cleaner/ghana-card-upload"
  def success_path, do: "/join-as-cleaner/ghana-card-upload/success"

  def sign_token(%{lead_id: lead_id, side: side, exp: exp}) do
    body = Jason.encode!(%{leadId: lead_id, side: side, exp: exp})
    sig = hmac_hex(secret!(), body)
    "#{b64url(body)}.#{sig}"
  end

  def verify_token(token) when is_binary(token) do
    case String.split(token, ".", parts: 2) do
      [enc, sig] ->
        with {:ok, body} <- decode_b64url(enc),
             true <- Plug.Crypto.secure_compare(hmac_hex(secret!(), body), sig),
             {:ok, payload} <- Jason.decode(body),
             side when side in ["front", "back"] <- payload["side"],
             true <- is_integer(payload["exp"]) and payload["exp"] >= System.system_time(:second),
             lead_id when is_binary(lead_id) and lead_id != "" <- payload["leadId"] do
          {:ok, %{lead_id: lead_id, side: side, exp: payload["exp"]}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def verify_token(_), do: :error

  def build_upload_url(lead_id, side) do
    exp = System.system_time(:second) + 2 * 60 * 60
    token = sign_token(%{lead_id: lead_id, side: side, exp: exp})
    encoded = URI.encode_www_form(token)
    fallback = "#{app_url()}#{upload_page_path()}?t=#{encoded}&side=#{side}"

    if Application.get_env(:mithril, :whatsapp_recruitment_store) ==
         Mithril.WhatsApp.Recruitment.Leads.Memory do
      {:ok, fallback}
    else
      expires_at = DateTime.from_unix!(exp)
      now = DateTime.utc_now()

      with :ok <- revoke_open_links(lead_id, side, now),
           {:ok, short_code, link_id} <- insert_link(lead_id, side, expires_at),
           :ok <- insert_token(link_id, token) do
        {:ok, "#{app_url()}/u/#{short_code}"}
      else
        _ -> {:ok, fallback}
      end
    end
  end

  def existing_path(lead, side) do
    verification =
      if side == "front",
        do: get_in(lead.payload, ["verification", "ghanaCardFrontPath"]),
        else: get_in(lead.payload, ["verification", "ghanaCardBackPath"])

    flow_path = get_in(lead.payload, ["_flow", "ghanaUploadReadyPath"])
    flow_side = get_in(lead.payload, ["_flow", "ghanaUploadReadySide"])
    row_path = if side == "front", do: lead.ghana_card_front_path, else: lead.ghana_card_back_path

    candidates =
      [verification, if(flow_side == side, do: flow_path), row_path]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    Enum.find(candidates, &Storage.download_ok?/1) || latest_stored(lead.id, side)
  end

  def latest_stored(lead_id, side) do
    folder = "recruitment/#{lead_id}"
    prefix = "ghana-#{side}-"

    Enum.find(Storage.list_latest(folder, prefix), &Storage.download_ok?/1)
  end

  def handle_browser_upload(params) do
    file = Map.get(params, "file")
    short_code = String.trim(to_string(Map.get(params, "code") || Map.get(params, "short_code") || ""))
    legacy_token = String.trim(to_string(Map.get(params, "t") || ""))

    cond do
      not upload?(file) ->
        {:html_error, 400, "Upload issue", "Please choose a Ghana Card photo and try again."}

      upload_size(file) > Storage.max_bytes() ->
        {:html_error, 400, "File too large",
         "This image is too large. Please upload a JPG, PNG, or WebP under 5 MB."}

      true ->
        save_upload(file, short_code, legacy_token)
    end
  end

  def html_error(title, message) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width,initial-scale=1"/>
        <title>#{xml(title)}</title>
        <style>
          body{font-family:system-ui,sans-serif;padding:24px;line-height:1.5;color:#0f172a;background:#f8fafc;}
          .card{max-width:480px;margin:0 auto;border:1px solid #e2e8f0;border-radius:16px;padding:20px;background:#fff;}
          .ttl{font-size:20px;font-weight:700;margin-bottom:8px;}
          .btn{display:inline-block;margin-top:16px;padding:12px 16px;border-radius:10px;background:#0D1859;color:#fff;text-decoration:none;font-weight:600;}
        </style>
      </head>
      <body>
        <div class="card">
          <div class="ttl">#{xml(title)}</div>
          <p>#{xml(message)}</p>
          <a class="btn" href="javascript:history.back()">Choose another photo</a>
        </div>
      </body>
    </html>
    """
  end

  defp save_upload(file, short_code, legacy_token) do
    with {:ok, payload, upload_link_id} <- resolve_token(short_code, legacy_token),
         {:ok, binary} <- read_upload(file),
         content_type when is_binary(content_type) <- Storage.sniff(binary),
         ext <- ext_for(content_type),
         path <- "recruitment/#{payload.lead_id}/ghana-#{payload.side}-#{System.system_time(:millisecond)}.#{ext}",
         :ok <- Storage.upload(path, binary, content_type),
         {:ok, lead} <- Leads.get(payload.lead_id) do
      flow =
        lead.payload
        |> Map.get("_flow", %{})
        |> Map.merge(%{"ghanaUploadReadyPath" => path, "ghanaUploadReadySide" => payload.side})

      payload_map = Map.put(lead.payload, "_flow", flow)

      with :ok <- Leads.persist(lead.phone, %{payload: payload_map}),
           :ok <- claim_link(upload_link_id) do
        {:redirect, "#{app_url()}#{success_path()}"}
      else
        {:error, :already_used} ->
          {:html_error, 409, "Link already used",
           "This upload link is no longer valid. In WhatsApp, reply LINK for a new upload link."}

        _ ->
          {:html_error, 500, "Could not finalize upload",
           "Your file may have been saved, but we could not update your application. Reply LINK in WhatsApp."}
      end
    else
      {:error, :bad_link} ->
        {:html_error, 401, "Link no longer works",
         "This upload link is invalid or has expired. In WhatsApp, reply LINK for a new upload link."}

      {:error, :expired} ->
        {:html_error, 401, "Link expired",
         "This upload link has expired. In WhatsApp, reply LINK for a new upload link."}

      nil ->
        {:html_error, 400, "Unsupported file type",
         "Please upload a JPG, PNG, or WebP image of your Ghana Card."}

      {:error, :upload_failed} ->
        {:html_error, 502, "Upload failed",
         "We could not save your photo. Go back to WhatsApp and reply LINK for a new upload link."}

      {:error, :not_found} ->
        {:html_error, 404, "Something went wrong",
         "We could not find your application. Please reply LINK in WhatsApp."}

      _ ->
        {:html_error, 500, "Something went wrong",
         "An unexpected error occurred. Reply LINK in WhatsApp for a new upload link."}
    end
  end

  defp resolve_token(short_code, _legacy) when short_code != "" do
    sql = """
    SELECT l.id, l.lead_id, l.side, l.expires_at, l.used_at, l.revoked_at, t.upload_token
    FROM public.cleaner_upload_links l
    JOIN public.cleaner_upload_link_tokens t ON t.upload_link_id = l.id
    WHERE l.short_code = $1
    LIMIT 1
    """

    case Repo.query(sql, [short_code]) do
      {:ok, %{rows: [[id, lead_id, side, expires_at, used_at, revoked_at, token]]}} ->
        cond do
          used_at || revoked_at ->
            {:error, :bad_link}

          DateTime.compare(to_dt(expires_at), DateTime.utc_now()) != :gt ->
            {:error, :expired}

          true ->
            with {:ok, payload} <- verify_token(token),
                 true <- payload.lead_id == uuid(lead_id) and payload.side == side do
              {:ok, payload, uuid(id)}
            else
              _ -> {:error, :bad_link}
            end
        end

      _ ->
        {:error, :bad_link}
    end
  end

  defp resolve_token(_short_code, legacy_token) when legacy_token != "" do
    with {:ok, payload} <- verify_token(legacy_token) do
      {:ok, payload, nil}
    else
      _ -> {:error, :bad_link}
    end
  end

  defp resolve_token(_, _), do: {:error, :bad_link}

  defp claim_link(nil), do: :ok

  defp claim_link(id) do
    with {:ok, uuid} <- Ecto.UUID.dump(id),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             """
             UPDATE public.cleaner_upload_links
             SET used_at = now()
             WHERE id = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > now()
             """,
             [uuid]
           ) do
      :ok
    else
      _ -> {:error, :already_used}
    end
  end

  defp revoke_open_links(lead_id, side, now) do
    with {:ok, uuid} <- Ecto.UUID.dump(lead_id),
         {:ok, _} <-
           Repo.query(
             """
             UPDATE public.cleaner_upload_links
             SET revoked_at = $3
             WHERE lead_id = $1 AND side = $2 AND used_at IS NULL AND revoked_at IS NULL
             """,
             [uuid, side, now]
           ) do
      :ok
    else
      _ -> {:error, :link_failed}
    end
  end

  defp insert_link(lead_id, side, expires_at) do
    with {:ok, uuid} <- Ecto.UUID.dump(lead_id) do
      Enum.reduce_while(1..12, {:error, :link_failed}, fn _, acc ->
        short_code = short_code()

        case Repo.query(
               """
               INSERT INTO public.cleaner_upload_links (short_code, lead_id, side, expires_at)
               VALUES ($1, $2, $3, $4)
               RETURNING id
               """,
               [short_code, uuid, side, expires_at]
             ) do
          {:ok, %{rows: [[id]]}} -> {:halt, {:ok, short_code, uuid(id)}}
          {:error, %{postgres: %{code: :unique_violation}}} -> {:cont, acc}
          {:error, _} -> {:halt, {:error, :link_failed}}
        end
      end)
    else
      _ -> {:error, :link_failed}
    end
  end

  defp insert_token(link_id, token) do
    with {:ok, uuid} <- Ecto.UUID.dump(link_id),
         {:ok, _} <-
           Repo.query(
             "INSERT INTO public.cleaner_upload_link_tokens (upload_link_id, upload_token) VALUES ($1, $2)",
             [uuid, token]
           ) do
      :ok
    else
      _ -> {:error, :link_failed}
    end
  end

  defp short_code do
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    len = 6 + :rand.uniform(7) - 1

    1..len
    |> Enum.map(fn _ -> Enum.at(alphabet, :rand.uniform(length(alphabet)) - 1) end)
    |> List.to_string()
  end

  defp secret! do
    secret = Application.get_env(:mithril, :recruitment_upload_secret)

    if is_binary(secret) and secret != "" do
      secret
    else
      raise "Missing RECRUITMENT_UPLOAD_SECRET"
    end
  end

  defp app_url do
    (Application.get_env(:mithril, :app_url) || "https://tryinstaclean.com")
    |> String.trim_trailing("/")
  end

  defp hmac_hex(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp b64url(value) do
    value |> Base.encode64() |> String.replace("+", "-") |> String.replace("/", "_") |> String.replace("=", "")
  end

  defp decode_b64url(value) do
    padded =
      case rem(String.length(value), 4) do
        0 -> value
        n -> value <> String.duplicate("=", 4 - n)
      end

    padded
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> Base.decode64()
  end

  defp upload?(%Plug.Upload{}), do: true
  defp upload?(_), do: false

  defp upload_size(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp read_upload(%Plug.Upload{path: path}), do: File.read(path)

  defp ext_for("image/png"), do: "png"
  defp ext_for("image/webp"), do: "webp"
  defp ext_for(_), do: "jpg"

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, id} -> id
      :error -> value
    end
  end

  defp to_dt(%DateTime{} = value), do: value
  defp to_dt(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_dt(value), do: value

  defp xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
