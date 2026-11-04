defmodule Mithril.WhatsApp.ContentTemplate do
  @moduledoc false

  alias Mithril.Repo
  alias Mithril.WhatsApp.ContentApi

  @doc """
  Returns an env Content SID when set. Otherwise creates the Twilio Content
  template, stores its SID, and submits it for WhatsApp approval.
  """
  def ensure(name, env_key, definition)
      when is_binary(name) and is_atom(env_key) and is_map(definition) do
    case env_sid(env_key) do
      sid when is_binary(sid) -> {:ok, sid}
      _ -> ensure_stored(name, definition)
    end
  end

  def content_sid(name, env_key) when is_binary(name) and is_atom(env_key) do
    env_sid(env_key) || stored_sid(name)
  end

  defp ensure_stored(name, definition) do
    case stored_template(name) do
      {sid, "submitted"} when is_binary(sid) -> {:ok, sid}
      {sid, _status} when is_binary(sid) -> approve_and_mark(name, sid)
      _ -> create(name, definition)
    end
  end

  defp create(name, definition) do
    case ContentApi.create(definition) do
      {:ok, sid} ->
        _ = store_sid(name, sid)
        approve_and_mark(name, sid)

      other ->
        other
    end
  end

  defp approve_and_mark(name, sid) do
    case ContentApi.submit_approval(sid, name) do
      :ok -> mark_submitted(name, sid)
      {:ok, _} -> mark_submitted(name, sid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_submitted(name, sid) do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             """
             UPDATE public.whatsapp_content_templates
             SET approval_status = 'submitted', updated_at = now()
             WHERE name = $1 AND content_sid = $2
             """,
             [name, sid]
           ) do
        {:ok, _} -> {:ok, sid}
        {:error, _} -> {:error, :template_not_created}
      end
    else
      {:ok, sid}
    end
  end

  defp env_sid(env_key) do
    case Application.get_env(:mithril, env_key) do
      sid when is_binary(sid) ->
        sid = String.trim(sid)
        if sid == "", do: nil, else: sid

      _ ->
        nil
    end
  end

  defp stored_sid(name) do
    case stored_template(name) do
      {sid, _} -> sid
      _ -> nil
    end
  end

  defp stored_template(name) do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             "SELECT content_sid, approval_status FROM public.whatsapp_content_templates WHERE name = $1",
             [name]
           ) do
        {:ok, %{rows: [[sid, status]]}} when is_binary(sid) and sid != "" -> {sid, status}
        _ -> nil
      end
    else
      nil
    end
  end

  defp store_sid(name, sid) do
    if table?("public.whatsapp_content_templates") do
      Repo.query(
        """
        INSERT INTO public.whatsapp_content_templates (name, content_sid, approval_status)
        VALUES ($1, $2, 'created')
        ON CONFLICT (name) DO UPDATE
          SET content_sid = EXCLUDED.content_sid,
              approval_status = 'created', updated_at = now()
        """,
        [name, sid]
      )
    else
      :ok
    end
  end

  defp table?(name) do
    case Repo.query("SELECT to_regclass($1)::text", [name]) do
      {:ok, %{rows: [[value]]}} when is_binary(value) and value != "" -> true
      _ -> false
    end
  end
end
