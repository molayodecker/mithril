defmodule Mithril.WorkerIdPass do
  @moduledoc """
  Signed Apple Wallet pass for a worker ID.

  The barcode is the public verify page. When the worker is suspended, the
  rebuilt pass is voided and phones that registered the pass are asked to
  refresh it. Signing certificates stay in server environment variables.
  This is not Apple Pay and does not use a merchant id.
  """

  alias Mithril.Repo
  alias Mithril.WorkerId

  require Logger

  @download_ttl_seconds 300
  @pass_type_default "pass.com.tryinstaclean.workerid"
  @team_default "82PYANC4C9"

  @spec issue(String.t()) :: {:ok, map()} | {:error, term()}
  def issue(user_id) when is_binary(user_id) do
    with {:ok, record} <- WorkerId.load_user(user_id),
         :ok <- ensure_configured(),
         :ok <- ensure_pass(record),
         {:ok, download} <- store_download(record.slug) do
      {:ok, %{"url" => download_url(record.slug, download)}}
    else
      {:error, :not_found} ->
        {:error,
         {:status, 404,
          %{error: "not_found", message: "Could not load your worker ID. Try again."}}}

      {:error, :invalid_user} ->
        {:error,
         {:status, 400, %{error: "invalid_user", message: "Sign in to view your worker ID."}}}

      {:error, :unavailable} ->
        {:error,
         {:status, 503,
          %{
            error: "worker_id_unavailable",
            message: "Could not load your worker ID. Try again."
          }}}

      {:error, :wallet_not_configured} ->
        {:error,
         {:status, 503,
          %{
            error: "wallet_not_configured",
            message: "Apple Wallet is not set up yet. Show this screen at check-in."
          }}}
    end
  end

  def issue(_user_id),
    do:
      {:error,
       {:status, 400, %{error: "invalid_user", message: "Sign in to view your worker ID."}}}

  @spec pkpass_for_download(String.t(), String.t()) ::
          {:ok, binary()} | {:error, :not_found | :wallet_not_configured | :unavailable}
  def pkpass_for_download(code, token) when is_binary(code) and is_binary(token) do
    slug = code |> String.trim() |> String.downcase()

    with {:ok, card} <- WorkerId.public_card(slug),
         :ok <- consume_download(slug, token),
         {:ok, auth_token} <- pass_token(slug) do
      build_pkpass(card, auth_token)
    end
  end

  def pkpass_for_download(_code, _token), do: {:error, :not_found}

  @spec pkpass_for_serial(String.t(), String.t()) ::
          {:ok, binary()}
          | {:error, :unauthorized | :not_found | :wallet_not_configured | :unavailable}
  def pkpass_for_serial(serial, apple_token) do
    with :ok <- authorize_serial(serial, apple_token),
         {:ok, card} <- WorkerId.public_card(serial) do
      build_pkpass(card, apple_token)
    end
  end

  @spec register(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized | :unavailable}
  def register(device, pass_type, serial, apple_token, push_token)
      when is_binary(device) and device != "" and is_binary(pass_type) and is_binary(serial) and
             serial != "" and is_binary(push_token) and push_token != "" do
    with :ok <- authorize_serial(serial, apple_token),
         :ok <- pass_type_matches?(pass_type) do
      insert_registration(device, pass_type, serial, push_token)
    end
  end

  def register(_, _, _, _, _), do: {:error, :unauthorized}

  @spec unregister(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized}
  def unregister(device, pass_type, serial, apple_token) do
    with :ok <- authorize_serial(serial, apple_token) do
      Repo.query(
        """
        DELETE FROM public.worker_id_pass_registrations
        WHERE device_library_identifier = $1
          AND pass_type_identifier = $2
          AND serial_number = $3
        """,
        [device, pass_type, serial]
      )

      :ok
    end
  end

  @spec serials(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | :none | {:error, :unavailable}
  def serials(device, pass_type, since) do
    since_unix =
      case Integer.parse(to_string(since || "0")) do
        {value, ""} when value >= 0 -> value
        _ -> 0
      end

    case Repo.query(
           """
           SELECT r.serial_number, p.updated_at
           FROM public.worker_id_pass_registrations r
           JOIN public.worker_id_passes p ON p.serial_number = r.serial_number
           WHERE r.device_library_identifier = $1
             AND r.pass_type_identifier = $2
           """,
           [device, pass_type]
         ) do
      {:ok, %{rows: []}} ->
        :none

      {:ok, %{rows: rows}} ->
        updated =
          Enum.filter(rows, fn [_serial, updated_at] -> unix(updated_at) > since_unix end)

        if updated == [] do
          :none
        else
          last =
            rows
            |> Enum.map(fn [_serial, updated_at] -> unix(updated_at) end)
            |> Enum.max()

          serial_numbers = Enum.map(updated, fn [serial, _updated] -> serial end)
          {:ok, %{"lastUpdated" => Integer.to_string(last), "serialNumbers" => serial_numbers}}
        end

      {:error, error} ->
        Logger.error("worker id pass list failed: #{Exception.message(error)}")
        {:error, :unavailable}
    end
  end

  @spec sync_user(term()) :: :ok | {:error, term()}
  def sync_user(user_id) do
    case WorkerId.load_user(user_id) do
      {:ok, record} ->
        touch_and_push(record)
        :ok

      {:error, :not_found} ->
        :ok

      {:error, :invalid_user} ->
        {:error, :invalid_user}

      {:error, :unavailable} ->
        {:error, :unavailable}
    end
  end

  @spec authorized_sync?(String.t() | nil) :: boolean()
  def authorized_sync?(header) when is_binary(header) do
    secret = System.get_env("WORKER_ID_SYNC_SECRET") |> blank_to_nil()

    case {secret, header} do
      {nil, _} ->
        false

      {secret, "Bearer " <> given} ->
        given = String.trim(given)
        byte_size(secret) == byte_size(given) and Plug.Crypto.secure_compare(secret, given)

      _ ->
        false
    end
  end

  def authorized_sync?(_header), do: false

  @spec pass_document(map(), String.t()) :: map()
  def pass_document(card, authentication_token)
      when is_map(card) and is_binary(authentication_token) do
    voided = card["statusLabel"] == "Suspended"
    background = if card["backgroundCleared"], do: "Cleared", else: "Pending"

    document = %{
      "formatVersion" => 1,
      "passTypeIdentifier" => pass_type_id(),
      "serialNumber" => serial_from_card(card),
      "teamIdentifier" => team_id(),
      "organizationName" => "Instaclean",
      "description" => "Instaclean Worker ID",
      "logoText" => "Instaclean",
      "foregroundColor" => "rgb(255, 255, 255)",
      "backgroundColor" => "rgb(13, 24, 89)",
      "labelColor" => "rgb(249, 213, 35)",
      "barcodes" => [
        %{
          "format" => "PKBarcodeFormatQR",
          "message" => card["verifyUrl"],
          "messageEncoding" => "iso-8859-1"
        }
      ],
      "generic" => %{
        "primaryFields" => [
          %{"key" => "name", "label" => "WORKER", "value" => card["name"]}
        ],
        "secondaryFields" => [
          %{"key" => "id", "label" => "ID", "value" => card["idNumber"]},
          %{"key" => "status", "label" => "STATUS", "value" => card["statusLabel"]}
        ],
        "auxiliaryFields" => [
          %{"key" => "check", "label" => "BACKGROUND", "value" => background}
        ]
      }
    }

    document =
      case https_origin() do
        nil ->
          document

        origin ->
          document
          |> Map.put("webServiceURL", origin <> "/wallet")
          |> Map.put("authenticationToken", authentication_token)
      end

    if voided, do: Map.put(document, "voided", true), else: document
  end

  defp build_pkpass(card, authentication_token) do
    with :ok <- ensure_configured() do
      document = pass_document(card, authentication_token)
      pass_json = Jason.encode!(document)
      icon = png(29, 29, {249, 213, 35})
      logo = png(160, 50, {249, 213, 35})

      manifest =
        Jason.encode!(%{
          "pass.json" => sha1(pass_json),
          "icon.png" => sha1(icon),
          "logo.png" => sha1(logo)
        })

      with {:ok, signature} <- sign_manifest(manifest) do
        files = [
          {~c"pass.json", pass_json},
          {~c"icon.png", icon},
          {~c"logo.png", logo},
          {~c"manifest.json", manifest},
          {~c"signature", signature}
        ]

        case :zip.create(~c"worker-id.pkpass", files, [:memory]) do
          {:ok, {_name, binary}} -> {:ok, binary}
          _ -> {:error, :wallet_not_configured}
        end
      end
    end
  end

  defp sign_manifest(manifest) do
    dir = Path.join(System.tmp_dir!(), "worker-id-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    manifest_path = Path.join(dir, "manifest.json")
    signature_path = Path.join(dir, "signature")
    File.write!(manifest_path, manifest)

    args =
      [
        "smime",
        "-binary",
        "-sign",
        "-signer",
        certificate_path(),
        "-inkey",
        key_path(),
        "-certfile",
        wwdr_path(),
        "-in",
        manifest_path,
        "-out",
        signature_path,
        "-outform",
        "DER"
      ] ++ passphrase_args()

    try do
      case System.cmd("openssl", args, stderr_to_stdout: true) do
        {_output, 0} -> {:ok, File.read!(signature_path)}
        {_output, _code} -> {:error, :wallet_not_configured}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp ensure_pass(record) do
    case Repo.query(
           "SELECT authentication_token FROM public.worker_id_passes WHERE user_id = $1",
           [record.user_id]
         ) do
      {:ok, %{rows: [[token]]}} when is_binary(token) ->
        Repo.query(
          """
          UPDATE public.worker_id_passes
          SET serial_number = $2, voided = $3, updated_at = now()
          WHERE user_id = $1
          """,
          [record.user_id, record.slug, record.void_pass]
        )

        :ok

      {:ok, %{rows: []}} ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        case Repo.query(
               """
               INSERT INTO public.worker_id_passes
                 (user_id, serial_number, authentication_token, voided)
               VALUES ($1, $2, $3, $4)
               """,
               [record.user_id, record.slug, token, record.void_pass]
             ) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Logger.error("worker id pass insert failed: #{Exception.message(error)}")
            {:error, :unavailable}
        end

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:error, :unavailable}

      {:error, error} ->
        Logger.error("worker id pass lookup failed: #{Exception.message(error)}")
        {:error, :unavailable}
    end
  end

  defp store_download(slug) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    hash = token_hash(token)
    expires_at = DateTime.add(DateTime.utc_now(), @download_ttl_seconds, :second)
    Repo.query("DELETE FROM public.worker_id_pass_downloads WHERE expires_at < now()", [])

    case Repo.query(
           """
           INSERT INTO public.worker_id_pass_downloads (token_hash, serial_number, expires_at)
           VALUES ($1, $2, $3)
           """,
           [hash, slug, expires_at]
         ) do
      {:ok, _} ->
        {:ok, token}

      {:error, error} ->
        Logger.error("worker id download token failed: #{Exception.message(error)}")
        {:error, :unavailable}
    end
  end

  defp consume_download(slug, token) do
    hash = token_hash(token)

    case Repo.query(
           """
           SELECT 1
           FROM public.worker_id_pass_downloads
           WHERE token_hash = $1
             AND serial_number = $2
             AND expires_at > now()
           """,
           [hash, slug]
         ) do
      {:ok, %{rows: [_row]}} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp pass_token(slug) do
    case Repo.query(
           "SELECT authentication_token FROM public.worker_id_passes WHERE serial_number = $1",
           [slug]
         ) do
      {:ok, %{rows: [[token]]}} when is_binary(token) -> {:ok, token}
      _ -> {:error, :not_found}
    end
  end

  defp authorize_serial(serial, apple_token) when is_binary(serial) and is_binary(apple_token) do
    case pass_token(serial) do
      {:ok, stored} ->
        if byte_size(stored) == byte_size(apple_token) and
             Plug.Crypto.secure_compare(stored, apple_token) do
          :ok
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp authorize_serial(_, _), do: {:error, :unauthorized}

  defp pass_type_matches?(pass_type) do
    if pass_type == pass_type_id(), do: :ok, else: {:error, :unauthorized}
  end

  defp insert_registration(device, pass_type, serial, push_token) do
    case Repo.query(
           """
           INSERT INTO public.worker_id_pass_registrations
             (device_library_identifier, pass_type_identifier, serial_number, push_token)
           VALUES ($1, $2, $3, $4)
           ON CONFLICT (device_library_identifier, pass_type_identifier, serial_number)
           DO UPDATE SET push_token = EXCLUDED.push_token
           """,
           [device, pass_type, serial, push_token]
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("worker id pass registration failed: #{Exception.message(error)}")
        {:error, :unavailable}
    end
  end

  defp touch_and_push(record) do
    case Repo.query(
           """
           UPDATE public.worker_id_passes
           SET voided = $2, updated_at = now()
           WHERE user_id = $1
           RETURNING serial_number
           """,
           [record.user_id, record.void_pass]
         ) do
      {:ok, %{rows: [[serial]]}} ->
        push_serial(serial)

      _ ->
        :ok
    end
  end

  defp push_serial(serial) do
    case Repo.query(
           "SELECT push_token FROM public.worker_id_pass_registrations WHERE serial_number = $1",
           [serial]
         ) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(&hd/1)
        |> Enum.filter(&is_binary/1)
        |> push_tokens()

      _ ->
        :ok
    end
  end

  defp push_tokens([]), do: :ok

  defp push_tokens(tokens) do
    case apns_jwt() do
      {:ok, jwt} -> Enum.each(tokens, &push_one(&1, jwt))
      :unconfigured -> :skipped
    end
  end

  defp push_one(token, jwt) do
    url = "https://api.push.apple.com/3/device/#{token}"

    result =
      Req.post(url,
        finch: Mithril.ApnsFinch,
        headers: [
          {"authorization", "bearer " <> jwt},
          {"apns-topic", pass_type_id()},
          {"apns-push-type", "background"},
          {"apns-priority", "5"}
        ],
        body: "{}"
      )

    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("worker id pass update push was not accepted: #{status}")

      {:error, reason} ->
        Logger.warning("worker id pass update push failed: #{inspect(reason)}")
    end
  end

  defp apns_jwt do
    key_path = System.get_env("APPLE_PASS_APNS_KEY_PATH") |> blank_to_nil()
    key_id = System.get_env("APPLE_PASS_APNS_KEY_ID") |> blank_to_nil()

    if key_path && key_id && File.regular?(key_path) do
      pem = File.read!(key_path)
      signer = Joken.Signer.create("ES256", %{"pem" => pem}, %{"kid" => key_id})
      claims = %{"iss" => team_id(), "iat" => System.system_time(:second)}

      case Joken.encode_and_sign(claims, signer) do
        {:ok, jwt, _claims} -> {:ok, jwt}
        _ -> :unconfigured
      end
    else
      :unconfigured
    end
  end

  defp ensure_configured do
    if File.regular?(certificate_path()) and File.regular?(key_path()) and
         File.regular?(wwdr_path()) do
      :ok
    else
      {:error, :wallet_not_configured}
    end
  end

  @doc false
  def materialize_secret(value, filename) when is_binary(value) and is_binary(filename) do
    cond do
      File.regular?(value) ->
        value

      String.contains?(value, "-----BEGIN") ->
        dir = Path.join(System.tmp_dir!(), "instaclean-wallet")
        File.mkdir_p!(dir)
        File.chmod!(dir, 0o700)
        path = Path.join(dir, filename)
        File.write!(path, String.trim(value) <> "\n")
        File.chmod!(path, 0o600)
        path

      true ->
        value
    end
  end

  defp certificate_path, do: secret_file("APPLE_PASS_CERTIFICATE_PATH", "pass.pem")
  defp key_path, do: secret_file("APPLE_PASS_KEY_PATH", "pass.key")
  defp wwdr_path, do: secret_file("APPLE_WWDR_CERTIFICATE_PATH", "wwdr.pem")

  defp secret_file(env_name, filename) do
    case System.get_env(env_name) |> blank_to_nil() do
      nil -> ""
      value -> materialize_secret(value, filename)
    end
  end

  defp passphrase_args do
    case System.get_env("APPLE_PASS_KEY_PASSPHRASE") |> blank_to_nil() do
      nil -> []
      passphrase -> ["-passin", "pass:" <> passphrase]
    end
  end

  defp download_url(slug, token) do
    origin = https_origin() || "https://api.tryinstaclean.com"
    "#{origin}/public/worker-ids/#{slug}/pass?token=#{URI.encode_www_form(token)}"
  end

  defp https_origin do
    origin = System.get_env("MITHRIL_PUBLIC_ORIGIN") || "https://api.tryinstaclean.com"
    if String.starts_with?(origin, "https://"), do: String.trim_trailing(origin, "/"), else: nil
  end

  defp pass_type_id do
    System.get_env("APPLE_PASS_TYPE_IDENTIFIER") |> blank_to_nil() || @pass_type_default
  end

  defp team_id do
    System.get_env("APPLE_TEAM_ID") |> blank_to_nil() || @team_default
  end

  defp serial_from_card(card) do
    card["verifyUrl"]
    |> to_string()
    |> String.split("/")
    |> List.last()
  end

  defp token_hash(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp sha1(bytes) do
    :crypto.hash(:sha, bytes) |> Base.encode16(case: :lower)
  end

  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)

  defp unix(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp unix(_value), do: 0

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp png(width, height, {red, green, blue}) do
    pixel = <<red, green, blue>>
    row = <<0>> <> for(_ <- 1..width, into: <<>>, do: pixel)
    raw = for(_ <- 1..height, into: <<>>, do: row)
    compressed = :zlib.compress(raw)

    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", ihdr) <> chunk("IDAT", compressed) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    crc = :erlang.crc32(type <> data)
    <<byte_size(data)::32, type::binary, data::binary, crc::32>>
  end
end
