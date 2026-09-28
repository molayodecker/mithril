defmodule Mithril.AdminBroadcast.Progress do
  @moduledoc false

  alias Mithril.AdminBroadcast.Delivery

  @spec next_batch([String.t()], non_neg_integer(), pos_integer()) ::
          {batch_ids :: [String.t()], new_offset :: non_neg_integer(), done? :: boolean()}
  def next_batch(recipient_ids, offset, batch_size) do
    batch_ids = Enum.slice(recipient_ids, offset, batch_size)
    new_offset = offset + length(batch_ids)
    done? = new_offset >= length(recipient_ids)
    {batch_ids, new_offset, done?}
  end

  @spec eligible_broadcast_statuses() :: [String.t()]
  def eligible_broadcast_statuses, do: ["queued", "sending"]

  @spec should_enqueue?(String.t()) :: boolean()
  def should_enqueue?(status) when is_binary(status), do: status in eligible_broadcast_statuses()
  def should_enqueue?(_), do: false

  @spec merge_progress(map(), map(), non_neg_integer(), [String.t()], non_neg_integer()) ::
          {merged_stats :: map(), new_offset :: non_neg_integer(), done? :: boolean(),
           final_status :: String.t() | nil}
  def merge_progress(broadcast_stats, batch_stats, offset, recipient_ids, batch_size) do
    merged = Delivery.merge_stats(broadcast_stats, batch_stats)
    {_batch_ids, new_offset, done?} = next_batch(recipient_ids, offset, batch_size)

    final_status =
      if done? do
        if Delivery.delivered_any?(merged), do: "completed", else: "failed"
      end

    {merged, new_offset, done?, final_status}
  end
end
