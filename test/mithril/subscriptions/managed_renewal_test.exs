defmodule Mithril.Subscriptions.ManagedRenewalTest do
  use ExUnit.Case, async: true

  alias Mithril.Subscriptions.ManagedRenewal

  describe "reference/2" do
    test "formats MGR id and date" do
      assert ManagedRenewal.reference("sub-1", "2099-03-04") == "MGR-sub-1-20990304"
    end
  end

  describe "should_initiate_charge?/2" do
    test "skips when already charged or paused" do
      refute ManagedRenewal.should_initiate_charge?(:charged, :not_found)
      refute ManagedRenewal.should_initiate_charge?(:paid, :not_found)
      refute ManagedRenewal.should_initiate_charge?(:paused, :not_found)
    end

    test "initiates when attempt open and verify not found" do
      assert ManagedRenewal.should_initiate_charge?(:pending, :not_found)
    end
  end

  describe "interpret_paystack/3" do
    test "404 is not_found" do
      assert :not_found = ManagedRenewal.interpret_paystack(404, %{}, "ref-1")
    end

    test "success transaction" do
      body = %{
        "status" => true,
        "data" => %{
          "status" => "success",
          "reference" => "MGR-x-20990101",
          "amount" => 12_500,
          "currency" => "GHS"
        }
      }

      assert {:success, "MGR-x-20990101", 12_500, "GHS"} =
               ManagedRenewal.interpret_paystack(200, body, "MGR-x-20990101")
    end

    test "missing data with not found message" do
      body = %{"status" => false, "message" => "Transaction not found"}

      assert :not_found = ManagedRenewal.interpret_paystack(200, body, "ref-1")
    end

    test "paused charge" do
      body = %{
        "status" => true,
        "data" => %{
          "status" => "pending",
          "paused" => true,
          "authorization_url" => "https://paystack.com/pause",
          "reference" => "MGR-y-20990102"
        }
      }

      assert {:paused, "MGR-y-20990102", "https://paystack.com/pause"} =
               ManagedRenewal.interpret_paystack(200, body, "MGR-y-20990102")
    end
  end

  describe "run/1 concurrency and idempotency" do
    test "already paid attempt never charges again" do
      deps = minimal_deps(%{status: :paid})

      assert {:ok, :skipped, %{}} = ManagedRenewal.run(deps)
      assert deps.charge_calls.() == 0
    end

    test "deterministic reference is reused on retry after verify not_found" do
      ref = ManagedRenewal.reference("sub-9", "2099-04-01")

      deps =
        minimal_deps(%{
          status: :pending_charge,
          paystack_reference: ref,
          verify: :not_found,
          charge: {:success, ref, 12_500, "GHS"}
        })

      assert {:ok, :paid, _} = ManagedRenewal.run(deps)
      assert Agent.get(deps_agent(), & &1.charge_count) == 1
      assert Agent.get(deps_agent(), & &1.last_reference) == ref
    end

    test "Paystack success after local crash does not double charge on retry" do
      ref = ManagedRenewal.reference("sub-10", "2099-04-02")

      deps =
        minimal_deps(%{
          status: :charged,
          paystack_reference: ref,
          verify: {:success, ref, 12_500, "GHS"},
          booking_payment_status: "paid"
        })

      assert {:ok, :paid, _} = ManagedRenewal.run(deps)
      assert Agent.get(deps_agent(), & &1.charge_count) == 0
    end

    test "pending Paystack transaction does not trigger a second charge" do
      ref = ManagedRenewal.reference("sub-12", "2099-04-04")

      deps =
        minimal_deps(%{
          status: :pending_charge,
          paystack_reference: ref,
          verify: {:pending, ref, "processing"}
        })

      assert {:ok, :waiting, %{reason: "processing"}} = ManagedRenewal.run(deps)
      assert deps.charge_calls.() == 0
    end

    test "Oban retry after success verifies Paystack instead of charging again" do
      ref = ManagedRenewal.reference("sub-13", "2099-04-05")

      deps =
        minimal_deps(%{
          status: :pending_charge,
          paystack_reference: ref,
          verify: {:success, ref, 12_500, "GHS"},
          charge: {:success, ref, 12_500, "GHS"}
        })

      assert {:ok, :paid, _} = ManagedRenewal.run(deps)
      assert deps.charge_calls.() == 0
    end

    test "charged attempt with missing verify does not initiate a second charge" do
      ref = ManagedRenewal.reference("sub-11", "2099-04-03")

      deps =
        minimal_deps(%{
          status: :charged,
          paystack_reference: ref,
          verify: :not_found
        })

      assert {:ok, :failed, %{error: "charged_but_verify_missing"}} = ManagedRenewal.run(deps)
      assert Agent.get(deps_agent(), & &1.charge_count) == 0
    end
  end

  defp deps_agent do
    case Process.get(:managed_renewal_test_agent) do
      nil ->
        {:ok, pid} = Agent.start_link(fn -> %{charge_count: 0, last_reference: nil} end)
        Process.put(:managed_renewal_test_agent, pid)
        pid

      pid ->
        pid
    end
  end

  defp minimal_deps(overrides) do
    agent = deps_agent()
    Agent.update(agent, fn _ -> %{charge_count: 0, last_reference: nil} end)

    attempt = %{
      status: Map.get(overrides, :status, :pending_charge),
      paystack_reference: Map.get(overrides, :paystack_reference, "MGR-x-20990101"),
      booking_id: nil
    }

    verify_kind =
      case Map.get(overrides, :verify, :not_found) do
        :not_found -> :not_found
        {:success, ref, 12_500, "GHS"} -> {:success, ref, 12_500, "GHS"}
        other -> other
      end

    charge_result =
      Map.get(overrides, :charge, {:success, attempt.paystack_reference, 12_500, "GHS"})

    %{
      claim_attempt: fn -> attempt end,
      update_attempt: fn _patch -> :ok end,
      verify_reference: fn _ref ->
        case verify_kind do
          :not_found -> :not_found
          {:success, ref, amount, currency} -> {:success, ref, amount, currency}
          other -> other
        end
      end,
      charge_authorization: fn params ->
        Agent.update(agent, fn state ->
          %{
            state
            | charge_count: state.charge_count + 1,
              last_reference: params.reference
          }
        end)

        case charge_result do
          {:success, ref, amount, currency} -> {:success, ref, amount, currency}
          other -> other
        end
      end,
      find_booking: fn ->
        case Map.get(overrides, :booking_payment_status) do
          nil -> nil
          status -> %{id: Ecto.UUID.generate(), payment_status: status}
        end
      end,
      insert_booking: fn ref -> {:ok, %{id: Ecto.UUID.generate(), reference: ref}} end,
      mark_booking_paid: fn _id -> :ok end,
      advance_recurrence: fn -> :ok end,
      authorization_code: "AUTH_test",
      email: "customer@example.com",
      amount_minor: 12_500,
      currency: "GHS",
      charge_calls: fn -> Agent.get(agent, & &1.charge_count) end
    }
  end
end
