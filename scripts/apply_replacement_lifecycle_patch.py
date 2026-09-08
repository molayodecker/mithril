from pathlib import Path


def replace_once(path, old, new):
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"Missing patch target in {path}: {old[:100]!r}")
    file.write_text(text.replace(old, new, 1))


replace_once(
    "lib/mithril/direct_dispatch.ex",
    '''         {:ok, input} <- validate_replacement_request(params),
         {:ok, booking} <- fetch_replaceable_booking(uid, bid),
         {:ok, result} <-''',
    '''         {:ok, input} <- validate_replacement_request(params),
         {:ok, booking} <- fetch_replaceable_booking(uid, bid),
         {:ok, requested_start_at} <- replacement_requested_start(input, booking),
         {:ok, result} <-''',
)
replace_once(
    "lib/mithril/direct_dispatch.ex",
    '''               booking.requested_start_at,
               booking.duration_hours,''',
    '''               requested_start_at,
               booking.duration_hours,''',
)
replace_once(
    "lib/mithril/direct_dispatch.ex",
    '''        if String.downcase(to_string(status)) in ~w(completed cancelled) do
          {:error, :booking_closed}
        else''',
    '''        if String.downcase(to_string(status)) not in ~w(pending confirmed scheduled) do
          {:error, :booking_closed}
        else''',
)
replace_once(
    "lib/mithril/direct_dispatch.ex",
    '''  defp validate_replacement_request(params) do
    with {:ok, priority} <- priority(params["priority"] || "same_day"),
         {:ok, request_requirements} <- requirements(params["requirements"]) do
      {:ok,
       %{
         priority: priority,
         requirements: request_requirements,
         notes: optional_text(params["notes"], 4_000)
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end
''',
    '''  defp validate_replacement_request(params) do
    with {:ok, priority} <- priority(params["priority"] || "same_day"),
         {:ok, needed_by} <- optional_iso_datetime(params["neededBy"]),
         {:ok, request_requirements} <- requirements(params["requirements"]) do
      {:ok,
       %{
         priority: priority,
         needed_by: needed_by,
         requirements: request_requirements,
         notes: optional_text(params["notes"], 4_000)
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp replacement_requested_start(%{needed_by: %DateTime{} = needed_by}, _booking) do
    minimum = DateTime.add(DateTime.utc_now(), 60, :second)

    if DateTime.compare(needed_by, minimum) == :gt,
      do: {:ok, needed_by},
      else: {:error, :needed_by_past}
  end

  defp replacement_requested_start(%{needed_by: nil}, %{requested_start_at: requested_start_at}) do
    minimum = DateTime.add(DateTime.utc_now(), 60, :second)

    if DateTime.compare(requested_start_at, minimum) == :gt,
      do: {:ok, requested_start_at},
      else: {:error, :replacement_time_required}
  end
''',
)
replace_once(
    "lib/mithril/direct_dispatch.ex",
    '''  defp iso_datetime(_), do: :error

  defp duration_hours''',
    '''  defp iso_datetime(_), do: :error

  defp optional_iso_datetime(nil), do: {:ok, nil}
  defp optional_iso_datetime(""), do: {:ok, nil}
  defp optional_iso_datetime(value), do: iso_datetime(value)

  defp duration_hours''',
)

replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''           SELECT cleaner_id, status, payment_status, service_id
           FROM public.bookings''',
    '''           SELECT cleaner_id, status, payment_status, service_id, timezone
           FROM public.bookings''',
)
replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''      {:ok, %{rows: [[current_worker, status, payment_status, ^service_id]]}} ->
        cond do''',
    '''      {:ok, %{rows: [[current_worker, status, payment_status, ^service_id, timezone]]}} ->
        cond do''',
)
replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''          String.downcase(to_string(status)) in ~w(cancelled completed) ->
            {:error, :booking_closed}''',
    '''          String.downcase(to_string(status)) not in ~w(pending confirmed scheduled) ->
            {:error, :booking_closed}''',
)
replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''            persist_replacement_handoff(booking_id, current_worker, worker_uid)''',
    '''            persist_replacement_handoff(
              booking_id,
              current_worker,
              worker_uid,
              request.requested_start_at,
              request.duration_hours,
              timezone
            )''',
)
replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''      {:ok, %{rows: [[_, _, _, _]]}} ->''',
    '''      {:ok, %{rows: [[_, _, _, _, _]]}} ->''',
)
replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''  defp persist_replacement_handoff(booking_id, previous_worker, worker_uid) do''',
    '''  defp persist_replacement_handoff(
         booking_id,
         previous_worker,
         worker_uid,
         requested_start_at,
         duration_hours,
         timezone
       ) do''',
)
replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''             SET cleaner_id = $2,
                 direct_assigned_cleaner_id = $2,
                 cleaner_accepted_at = now(),''',
    '''             SET cleaner_id = $2,
                 direct_assigned_cleaner_id = $2,
                 scheduled_date = (($3::timestamptz AT TIME ZONE COALESCE(NULLIF($5::text, ''), 'Africa/Accra'))::date),
                 scheduled_time = (($3::timestamptz AT TIME ZONE COALESCE(NULLIF($5::text, ''), 'Africa/Accra'))::time),
                 booking_period = tstzrange(
                   $3::timestamptz,
                   $3::timestamptz + make_interval(secs => ($4::numeric * 3600)::double precision),
                   '[)'
                 ),
                 cleaner_accepted_at = now(),''',
)
replace_once(
    "lib/mithril/direct_dispatch_safety.ex",
    '''             [booking_id, worker_uid]
           ) do''',
    '''             [booking_id, worker_uid, requested_start_at, duration_hours, timezone]
           ) do''',
)

replace_once(
    "lib/mithril_web/schemas/direct_dispatch.ex",
    '''        priority: %Schema{type: :string, enum: ~w(urgent same_day standard), default: "same_day"},
        requirements:''',
    '''        priority: %Schema{type: :string, enum: ~w(urgent same_day standard), default: "same_day"},
        neededBy: %Schema{type: :string, format: :"date-time", nullable: true},
        requirements:''',
)
replace_once(
    "lib/mithril_web/controllers/direct_dispatch_controller.ex",
    '''  defp error_response(:needed_by_past), do: {422, "needed_by_past"}
''',
    '''  defp error_response(:needed_by_past), do: {422, "needed_by_past"}
  defp error_response(:replacement_time_required), do: {422, "replacement_time_required"}
''',
)

replace_once(
    "test/mithril/direct_dispatch_safety_test.exs",
    '''      duration_hours numeric NOT NULL,
      timezone text,''',
    '''      duration_hours numeric NOT NULL,
      timezone text,
      booking_period tstzrange,''',
)
replace_once(
    "test/mithril/direct_dispatch_safety_test.exs",
    '''        duration_hours, timezone, status, payment_status
      ) VALUES ($1, $2, $4, 1, 'Labone, Accra', '2026-09-08', '10:00', 3,
                'Africa/Accra', 'pending', $3)''',
    '''        duration_hours, timezone, booking_period, status, payment_status
      ) VALUES ($1, $2, $4, 1, 'Labone, Accra', '2026-09-08', '10:00', 3,
                'Africa/Accra', tstzrange('2026-09-08T10:00:00Z', '2026-09-08T13:00:00Z', '[)'), 'pending', $3)''',
)
marker = '''  test "rejects dispatch assignment on a worker availability exception" do
'''
tests = '''  test "rejects replacement requests once a booking is already in progress" do
    customer_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()

    insert_booking!(booking_id, customer_id, "paid")
    Repo.query!("UPDATE public.bookings SET status = 'in_progress' WHERE id = $1", [
      Ecto.UUID.dump!(booking_id)
    ])

    assert {:error, :booking_closed} =
             DirectDispatchSafety.request_replacement(customer_id, booking_id, %{
               "priority" => "urgent",
               "neededBy" => "2026-09-08T12:00:00Z"
             })
  end

  test "late replacement accepts a new future start time" do
    customer_id = Ecto.UUID.generate()
    booking_id = Ecto.UUID.generate()

    insert_booking!(booking_id, customer_id, "paid")
    Repo.query!(
      "UPDATE public.bookings SET scheduled_date = '2026-09-07', scheduled_time = '10:00' WHERE id = $1",
      [Ecto.UUID.dump!(booking_id)]
    )

    assert {:ok, request} =
             DirectDispatchSafety.request_replacement(customer_id, booking_id, %{
               "priority" => "urgent",
               "neededBy" => "2026-09-08T12:00:00Z"
             })

    [[requested_start_at]] =
      Repo.query!(
        "SELECT requested_start_at FROM public.direct_service_requests WHERE id = $1",
        [Ecto.UUID.dump!(request.id)]
      ).rows

    assert requested_start_at == ~U[2026-09-08 12:00:00Z]
  end

'''
file = Path("test/mithril/direct_dispatch_safety_test.exs")
text = file.read_text()
if marker not in text:
    raise SystemExit("Missing test insertion marker")
file.write_text(text.replace(marker, tests + marker, 1))
