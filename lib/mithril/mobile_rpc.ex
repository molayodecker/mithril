defmodule Mithril.MobileRpc do
  @moduledoc false

  @names MapSet.new(~w(
    accept_booking_assignment
    accept_co_cleaner_invite
    accept_preferred_cleaner_invite
    apply_referral_code
    assign_cleaner_after_payment
    attach_booking_micro_tasks
    cleanup_failed_quick_tasks_booking
    cleanup_orphaned_pending_subscription
    complete_cleaner_booking
    compute_booking_pricing
    compute_booking_pricing_with_promotion
    compute_booking_pricing_with_promotion_and_transportation
    compute_booking_pricing_with_transportation
    compute_extra_task_labor_quotes
    compute_family_care_pricing
    compute_housekeeper_pricing
    compute_micro_task_booking_pricing
    compute_pet_care_pricing
    confirm_zero_amount_booking
    create_co_cleaner_invite
    create_direct_request
    create_preferred_cleaner_invite
    create_quick_tasks_booking
    decline_booking_by_cleaner
    delete_booking_job_photo
    delete_quick_task_upload
    evaluate_booking_risk_triggers
    fetch_cleaner_earnings
    get_active_pricing_rule
    get_ai_match_settings
    get_assigned_cleaner_for_customer_booking
    get_available_cleaners_for_booking
    get_best_available_cleaners
    get_booking_contact_phone
    get_booking_payment_snapshot
    get_booking_review_by_token
    get_cleaner_booking_access_context
    get_cleaner_booking_location_fields
    get_cleaner_by_booking_slug
    get_cleaner_hourly_rate_limits
    get_cleaner_profile_v1
    get_cleaner_transaction_history
    get_cleaners_with_distance
    get_customer_booking_verification_requirement
    get_direct_request
    get_latest_paystack_reference_for_booking
    get_my_cleaner_booking_link
    get_my_cleaner_team
    get_my_referral_info
    get_my_wallet_balance
    get_or_create_booking_conversation
    get_or_create_care_request_conversation
    get_own_booking_voucher_identity
    get_pending_booking_for_edit
    get_user_profile_data
    get_user_profile_stats
    get_user_role
    get_verification_service_catalog
    get_welcome_offer_eligibility
    is_co_cleaner_team_member
    is_location_in_active_service_area
    leave_co_cleaner_team
    list_broadcast_assignments_for_cleaner
    list_direct_requests_for_worker
    list_turnover_opportunities_for_customer
    log_customer_payment_failure
    lookup_sign_in_account
    manage_extra_tasks
    mark_cleaner_booking_milestone
    mark_conversation_messages_read
    peek_customer_booking_verification_requirement
    preview_customer_booking_verification_requirement
    queue_avatar_storage_deletion
    reconcile_payout_name_mismatch_flag
    register_booking_job_photo
    register_device_push_token
    register_quick_task_upload
    release_own_welcome_promotion_reservation
    remove_co_cleaner_from_team
    reserve_promotion_for_booking
    reserve_welcome_promotion_for_booking
    respond_to_care_request
    revoke_co_cleaner_invite
    revoke_preferred_cleaner_invite
    save_care_request_matches
    save_property_information
    set_default_payout_method
    set_property_auto_booking_enabled
    start_cleaner_booking
    submit_booking_review
    submit_booking_review_by_token
    submit_customer_review
    sync_profile_name_from_payout
    sync_recurring_unpaid_checkout_snapshots
    update_booking_status
    update_my_hourly_rate
    upsert_cleaner_team_name
    validate_promotion_code
  ))

  @arg ~r/^[a-z_][a-z0-9_]*$/

  def allowlisted?(name) when is_binary(name), do: MapSet.member?(@names, name)
  def allowlisted?(_), do: false

  def compile(name, args) when is_binary(name) and is_map(args) do
    with :ok <- validate_name(name),
         {:ok, pairs} <- arg_pairs(args) do
      {assignments, params} =
        pairs
        |> Enum.with_index(1)
        |> Enum.map(fn {{key, value}, index} ->
          {"#{key} := $#{index}", value}
        end)
        |> Enum.unzip()

      {:ok, %{name: name, assignments: Enum.join(assignments, ", "), params: params}}
    end
  end

  def compile(name, nil), do: compile(name, %{})
  def compile(_, _), do: {:error, :invalid_args}

  def sql(%{name: name, assignments: ""}, :set), do: "SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM public.#{name}() AS t"
  def sql(%{name: name, assignments: assignments}, :set), do: "SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM public.#{name}(#{assignments}) AS t"
  def sql(%{name: name, assignments: ""}, :void), do: "SELECT public.#{name}()"
  def sql(%{name: name, assignments: assignments}, :void), do: "SELECT public.#{name}(#{assignments})"
  def sql(%{name: name, assignments: ""}, :scalar), do: "SELECT to_jsonb(public.#{name}())"
  def sql(%{name: name, assignments: assignments}, :scalar), do: "SELECT to_jsonb(public.#{name}(#{assignments}))"

  defp validate_name(name) do
    if allowlisted?(name), do: :ok, else: {:error, :unknown_function}
  end

  defp arg_pairs(args) do
    pairs = Map.to_list(args)

    if Enum.all?(pairs, fn {key, _value} -> is_binary(key) and Regex.match?(@arg, key) end) do
      {:ok, pairs}
    else
      {:error, :invalid_args}
    end
  end
end
