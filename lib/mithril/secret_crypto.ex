defmodule Mithril.SecretCrypto do
  @moduledoc false

  @aad ""

  @spec encrypt(String.t()) :: {:ok, String.t()} | {:error, :not_configured}
  def encrypt(plaintext) when is_binary(plaintext) do
    with {:ok, key} <- encryption_key(),
         iv <- :crypto.strong_rand_bytes(12),
         {cipher, tag} <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, 16, true) do
      {:ok, Enum.join([Base.encode64(iv), Base.encode64(cipher), Base.encode64(tag)], ":")}
    else
      {:error, :not_configured} -> {:error, :not_configured}
    end
  end

  @spec hash_token(String.t()) :: String.t()
  def hash_token(value) when is_binary(value) do
    :crypto.hash(:sha256, String.trim(value))
    |> Base.encode16(case: :lower)
  end

  @spec decrypt(String.t()) :: {:ok, String.t()} | {:error, :not_configured | :invalid_payload}
  def decrypt(payload) when is_binary(payload) do
    case String.split(payload, ":", parts: 3) do
      [iv_part, cipher_part, tag_part] ->
        with {:ok, key} <- encryption_key(),
             {:ok, iv} <- Base.decode64(iv_part),
             {:ok, cipher} <- Base.decode64(cipher_part),
             {:ok, tag} <- Base.decode64(tag_part),
             plain when is_binary(plain) <-
               :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, @aad, tag, false) do
          {:ok, plain}
        else
          {:error, :not_configured} -> {:error, :not_configured}
          _ -> {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp encryption_key do
    case Application.get_env(:mithril, :otp_delivery_encryption_key) do
      key when is_binary(key) and key != "" ->
        case Base.decode64(String.trim(key)) do
          {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
          _ -> {:error, :not_configured}
        end

      _ ->
        {:error, :not_configured}
    end
  end
end
