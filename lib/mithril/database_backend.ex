defmodule Mithril.DatabaseBackend do
  @moduledoc false

  @valid_backends ~w(fly supabase)

  def resolve(get_env \\ &System.get_env/1) do
    backend = normalize_backend(get_env.("DATABASE_BACKEND") || "supabase")
    {backend, url_for(backend, get_env)}
  end

  def resolve!(get_env \\ &System.get_env/1) do
    {backend, url} = resolve(get_env)

    if is_nil(url) do
      raise ArgumentError, missing_url_message(backend)
    end

    {backend, url}
  end

  defp url_for("fly", get_env) do
    present(get_env.("FLY_DATABASE_URL"))
  end

  defp url_for("supabase", get_env) do
    present(get_env.("SUPABASE_DATABASE_URL")) || present(get_env.("DATABASE_URL"))
  end

  defp normalize_backend(backend) when backend in @valid_backends, do: backend

  defp normalize_backend(other) do
    raise ArgumentError,
          ~s(DATABASE_BACKEND must be "fly" or "supabase", got: #{inspect(other)})
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp missing_url_message("fly") do
    "DATABASE_BACKEND=fly requires FLY_DATABASE_URL"
  end

  defp missing_url_message("supabase") do
    "DATABASE_BACKEND=supabase requires SUPABASE_DATABASE_URL or DATABASE_URL"
  end
end
