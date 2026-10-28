defmodule Mithril.MobileFunctions.ReplaceCleanerWeeklyAvailability do
  @moduledoc false

  alias Mithril.DbUuid
  alias Mithril.MobileGateway
  alias Mithril.Repo

  @clock ~r/^([01]\d|2[0-3]):[0-5]\d$/

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(user_id, body) when is_binary(user_id) and is_map(body) do
    with {:ok, windows} <- normalize_windows(body["windows"] || body[:windows]) do
      case MobileGateway.with_user_transaction(user_id, fn ->
             replace_windows(user_id, windows)
           end) do
        {:ok, saved} ->
          {:ok, %{"windows" => saved}}

        {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
          {:error,
           {:status, 501,
            %{
              error: "weekly_hours_unavailable",
              message: "Saving weekly hours is not available yet."
            }}}

        {:error, %Postgrex.Error{}} ->
          {:error,
           {:status, 400,
            %{error: "weekly_hours_not_saved", message: "Could not save your hours."}}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def call(_user_id, _body), do: {:error, :bad_request}

  defp normalize_windows(windows) when is_list(windows) do
    normalized =
      Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, acc} ->
        case normalize_window(window) do
          {:ok, day} -> {:cont, {:ok, [day | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, days} <- normalized do
      days = Enum.reverse(days)
      day_numbers = Enum.map(days, & &1.day_of_week)

      cond do
        days == [] ->
          {:error,
           {:status, 400,
            %{
              error: "weekly_hours_empty",
              message: "Keep at least one working day. Use time off to block a whole week."
            }}}

        length(days) != length(Enum.uniq(day_numbers)) ->
          {:error,
           {:status, 400, %{error: "weekly_hours_duplicate", message: "Choose each day once."}}}

        true ->
          {:ok, days}
      end
    end
  end

  defp normalize_windows(_windows) do
    {:error,
     {:status, 400, %{error: "weekly_hours_invalid", message: "Choose your working days."}}}
  end

  defp normalize_window(window) when is_map(window) do
    day_of_week = window["day_of_week"] || window[:day_of_week]
    start_time = clock(window["start_time"] || window[:start_time])
    end_time = clock(window["end_time"] || window[:end_time])

    cond do
      not is_integer(day_of_week) or day_of_week < 0 or day_of_week > 6 ->
        {:error, {:status, 400, %{error: "weekly_hours_invalid", message: "Choose a valid day."}}}

      start_time == nil or end_time == nil ->
        {:error,
         {:status, 400, %{error: "weekly_hours_invalid", message: "Enter a start and end time."}}}

      start_time >= end_time ->
        {:error,
         {:status, 400,
          %{error: "weekly_hours_invalid", message: "End time must be after the start time."}}}

      true ->
        {:ok, %{day_of_week: day_of_week, start_time: start_time, end_time: end_time}}
    end
  end

  defp normalize_window(_window) do
    {:error, {:status, 400, %{error: "weekly_hours_invalid", message: "Choose a valid day."}}}
  end

  defp clock(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@clock, trimmed) do
      trimmed
    else
      nil
    end
  end

  defp clock(_value), do: nil

  defp replace_windows(user_id, windows) do
    cleaner_id = DbUuid.dump!(user_id)
    payload = Jason.encode!(windows)

    with {:ok, _} <-
           Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
             "weekly-availability:#{user_id}"
           ]),
         {:ok, _} <-
           Repo.query(
             """
             DELETE FROM public.availability
             WHERE cleaner_id = $1::uuid
               AND day_of_week IS NOT NULL
             """,
             [cleaner_id]
           ),
         {:ok, _} <-
           Repo.query(
             """
             INSERT INTO public.availability (
               cleaner_id, day_of_week, start_time, end_time, is_recurring
             )
             SELECT
               $1::uuid,
               weekly_day.day_of_week,
               ('2000-01-01 ' || weekly_day.start_time || ':00+00')::timestamptz,
               ('2000-01-01 ' || weekly_day.end_time || ':00+00')::timestamptz,
               true
             FROM jsonb_to_recordset(($2::text)::jsonb) AS weekly_day(
               day_of_week int,
               start_time text,
               end_time text
             )
             """,
             [cleaner_id, payload]
           ),
         {:ok, %{rows: rows}} <-
           Repo.query(
             """
             SELECT day_of_week,
                    to_char(start_time AT TIME ZONE 'UTC', 'HH24:MI'),
                    to_char(end_time AT TIME ZONE 'UTC', 'HH24:MI')
             FROM public.availability
             WHERE cleaner_id = $1::uuid
               AND day_of_week IS NOT NULL
             ORDER BY day_of_week
             """,
             [cleaner_id]
           ) do
      {:ok,
       Enum.map(rows, fn [day_of_week, start_time, end_time] ->
         %{
           "day_of_week" => day_of_week,
           "start_time" => start_time,
           "end_time" => end_time
         }
       end)}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
