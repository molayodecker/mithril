defmodule Mithril.WhatsApp.JobOfferTemplate do
  @moduledoc """
  WhatsApp template for the one worker who was just offered a job.

  The Accept and No buttons return payloads containing the unique offer ID.
  Free-text replies such as "yes" or "yes tomorrow" are not
  an acceptance. The body carries the date, time, and area, and keeps words
  after the last variable so WhatsApp can approve it.
  """

  alias Mithril.Repo
  alias Mithril.WhatsApp.ContentApi

  @name "instaclean_job_offer_accept_v2"
  @accept_payload "accept_job:"
  @decline_payload "decline_job:"
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def name, do: @name
  def accept_payload, do: @accept_payload
  def decline_payload, do: @decline_payload
  def accept_payload(offer_id), do: @accept_payload <> offer_id
  def decline_payload(offer_id), do: @decline_payload <> offer_id

  def body do
    "Instaclean offered you a job on {{1}} at {{2}} in {{3}}. Tap Accept to take it before this offer expires."
  end

  def definition do
    %{
      "friendly_name" => @name,
      "language" => "en",
      "variables" => %{
        "1" => "4 Nov 2026",
        "2" => "10:00",
        "3" => "East Legon",
        "4" => "00000000-0000-4000-8000-000000000001"
      },
      "types" => %{
        "twilio/quick-reply" => %{
          "body" => body(),
          "actions" => [
            %{"id" => @accept_payload <> "{{4}}", "title" => "Accept"},
            %{"id" => @decline_payload <> "{{4}}", "title" => "No"}
          ]
        }
      }
    }
  end

  def variables(%{offer_id: offer_id} = booking) do
    Map.put(variables(Map.delete(booking, :offer_id)), "4", offer_id)
  end

  def variables(%{date: date, time: time, address: address}) do
    %{
      "1" => display_date(date),
      "2" => display_time(time),
      "3" => area_label(address)
    }
  end

  def display_date(value) when is_binary(value) do
    case Date.from_iso8601(value |> String.trim() |> String.slice(0, 10)) do
      {:ok, date} ->
        month = Enum.at(@months, date.month - 1)
        "#{date.day} #{month} #{date.year}"

      _ ->
        clip(value, 24, "the scheduled day")
    end
  end

  def display_date(_), do: "the scheduled day"

  def display_time(value) when is_binary(value) do
    time = value |> String.trim() |> String.slice(0, 5)
    if time == "", do: "the scheduled time", else: time
  end

  def display_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  def display_time(_), do: "the scheduled time"

  @doc """
  Area shown before the worker accepts. A house number is not an area.
  """
  def area_label(address) when is_binary(address) do
    parts =
      address
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    area =
      case parts do
        [_street, locality | _] -> locality
        [single] -> if String.match?(single, ~r/\d/), do: "your area", else: single
        _ -> "your area"
      end

    clip(area, 40, "your area")
  end

  def area_label(_), do: "your area"

  def content_sid do
    env_sid() || stored_sid()
  end

  def ensure do
    case env_sid() do
      sid when is_binary(sid) and sid != "" -> {:ok, sid}
      _ -> ensure_stored()
    end
  end

  defp ensure_stored do
    case stored_template() do
      {sid, "submitted"} when is_binary(sid) -> {:ok, sid}
      {sid, _status} when is_binary(sid) -> approve_and_mark(sid)
      _ -> create()
    end
  end

  defp create do
    case ContentApi.create(definition()) do
      {:ok, sid} ->
        _ = store_sid(sid)
        approve_and_mark(sid)

      other ->
        other
    end
  end

  defp approve_and_mark(sid) do
    case ContentApi.submit_approval(sid, @name) do
      :ok -> mark_submitted(sid)
      {:ok, _} -> mark_submitted(sid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_submitted(sid) do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             """
             UPDATE public.whatsapp_content_templates
             SET approval_status = 'submitted', updated_at = now()
             WHERE name = $1 AND content_sid = $2
             """,
             [@name, sid]
           ) do
        {:ok, _} -> {:ok, sid}
        {:error, _} -> {:error, :template_not_created}
      end
    else
      {:ok, sid}
    end
  end

  defp env_sid do
    case Application.get_env(:mithril, :twilio_template_job_offer) do
      sid when is_binary(sid) ->
        sid = String.trim(sid)
        if sid == "", do: nil, else: sid

      _ ->
        nil
    end
  end

  defp stored_sid do
    case stored_template() do
      {sid, _} -> sid
      _ -> nil
    end
  end

  defp stored_template do
    if table?("public.whatsapp_content_templates") do
      case Repo.query(
             "SELECT content_sid, approval_status FROM public.whatsapp_content_templates WHERE name = $1",
             [@name]
           ) do
        {:ok, %{rows: [[sid, status]]}} when is_binary(sid) and sid != "" -> {sid, status}
        _ -> nil
      end
    else
      nil
    end
  end

  defp store_sid(sid) do
    if table?("public.whatsapp_content_templates") do
      Repo.query(
        """
        INSERT INTO public.whatsapp_content_templates (name, content_sid, approval_status)
        VALUES ($1, $2, 'created')
        ON CONFLICT (name) DO UPDATE
          SET content_sid = EXCLUDED.content_sid,
              approval_status = 'created', updated_at = now()
        """,
        [@name, sid]
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

  defp clip(value, max, fallback) do
    cleaned =
      value
      |> to_string()
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/[{}]/, "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, max)

    if cleaned == "", do: fallback, else: cleaned
  end
end
