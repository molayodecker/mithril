from pathlib import Path
p = Path('lib/mithril/direct_dispatch_safety.ex')
s = p.read_text()
old = '''  defp reassign_related_booking(
         %{kind: "replacement", related_booking_id: booking_id, related_service_id: service_id},
         worker_uid
       )'''
new = '''  defp reassign_related_booking(
         request = %{
           kind: "replacement",
           related_booking_id: booking_id,
           related_service_id: service_id
         },
         worker_uid
       )'''
if old not in s:
    raise SystemExit('replacement binding target not found')
p.write_text(s.replace(old, new, 1))
