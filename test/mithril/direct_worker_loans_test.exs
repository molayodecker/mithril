defmodule Mithril.DirectWorkerLoansTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias Mithril.DirectAdminActor
  alias Mithril.DirectAdminMoneyFixtures, as: Fixtures
  alias Mithril.DirectWorkerLoans
  alias Mithril.Repo
  alias MithrilWeb.DirectAdminWorkerLoansController
  alias MithrilWeb.DirectWorkerLoansController

  setup do
    Fixtures.checkout!()
    :ok
  end

  test "worker requests a loan and admin approves with wallet credit" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:ok,
            %{"status" => "pending", "amountMinor" => 25_000, "reason" => "Transport to site"}} =
             DirectWorkerLoans.create_request(worker_id, %{
               amountMinor: "25000",
               reason: "  Transport to site  "
             })

    assert {:error, :pending_request_exists} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 1_000})

    assert {:ok, [pending]} = DirectWorkerLoans.list_admin_requests(admin_id)
    assert pending["amountMinor"] == 25_000
    assert pending["reason"] == "Transport to site"
    assert pending["reviewedAt"] == nil

    request_id = pending["id"]

    assert {:ok, shown} = DirectWorkerLoans.show_admin_request(admin_id, request_id)
    assert shown["id"] == request_id

    assert {:ok, approved} =
             DirectWorkerLoans.review(admin_id, request_id, %{
               decision: :approve,
               reviewNotes: "Approved for travel"
             })

    assert approved["status"] == "approved"
    assert approved["newBalanceMinor"] == 25_000
    assert approved["outstandingMinor"] == 25_000

    assert {:ok, %{"outstandingMinor" => 25_000, "currency" => "GHS"}} =
             DirectWorkerLoans.worker_summary(worker_id)

    assert {:ok, requests} = DirectWorkerLoans.list_worker_requests(worker_id)
    assert hd(requests)["status"] == "approved"
    assert hd(requests)["reviewNotes"] == "Approved for travel"

    [[balance]] = Repo.query!("SELECT balance_subunit FROM public.wallets").rows
    assert balance == 25_000

    [[description]] =
      Repo.query!("SELECT description FROM public.wallet_transactions").rows

    assert description == "Loan advance — Transport to site"
  end

  test "admin can reject a pending request" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 10_000})

    assert {:ok, rejected} =
             DirectWorkerLoans.review(admin_id, created["id"], %{
               "decision" => "reject",
               "reviewNotes" => "Not now"
             })

    assert rejected["status"] == "rejected"
    assert rejected["outstandingMinor"] == 0

    assert {:ok, _} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 5_000})
  end

  test "loan recovery reduces net payout and outstanding balance" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    worker_uid = Ecto.UUID.dump!(worker_id)
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 40_000})

    assert {:ok, _} =
             DirectWorkerLoans.review(admin_id, created["id"], %{"decision" => "approve"})

    assert {:ok, recovery} =
             recover_loan!(admin_id, worker_uid, 50_000, booking_id)

    assert recovery["grossMinor"] == 50_000
    assert recovery["recoveryMinor"] == 40_000
    assert recovery["netMinor"] == 10_000
    assert recovery["outstandingMinor"] == 0

    assert {:ok, %{"outstandingMinor" => 0}} = DirectWorkerLoans.worker_summary(worker_id)
  end

  test "loan recovery is a no-op when there is no outstanding balance" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, recovery} =
             recover_loan!(admin_id, Ecto.UUID.dump!(worker_id), 12_000, booking_id)

    assert recovery["recoveryMinor"] == 0
    assert recovery["netMinor"] == 12_000
    assert recovery["outstandingMinor"] == 0
    assert recovery["loanEventId"] == nil
  end

  test "loan recovery takes only the outstanding amount" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    booking_id = Fixtures.insert_booking!(Fixtures.insert_user!())

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 8_000})

    assert {:ok, _} =
             DirectWorkerLoans.review(admin_id, created["id"], %{"decision" => :reject})

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 8_000})

    assert {:ok, _} =
             DirectWorkerLoans.review(admin_id, created["id"], %{"decision" => "approve"})

    assert {:ok, recovery} =
             recover_loan!(admin_id, Ecto.UUID.dump!(worker_id), 8_000, booking_id)

    assert recovery["recoveryMinor"] == 8_000
    assert recovery["netMinor"] == 0
    assert recovery["outstandingMinor"] == 0
  end

  test "strangers cannot review or impersonate workers" do
    worker_id = Fixtures.insert_worker!()
    stranger_id = Fixtures.insert_user!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 3_000})

    assert {:error, :forbidden} =
             DirectWorkerLoans.review(stranger_id, created["id"], %{"decision" => "approve"})

    assert {:error, :worker_not_found} = DirectWorkerLoans.list_worker_requests(stranger_id)
    assert {:error, :worker_not_found} = DirectWorkerLoans.worker_summary(stranger_id)
    assert {:error, :forbidden} = DirectWorkerLoans.list_admin_requests(stranger_id)
    assert {:error, :forbidden} = DirectWorkerLoans.show_admin_request(stranger_id, created["id"])
  end

  test "create and review reject invalid input" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    customer_id = Fixtures.insert_user!()

    assert {:error, :invalid_request} = DirectWorkerLoans.create_request(1, %{"amountMinor" => 1})
    assert {:error, :invalid_request} = DirectWorkerLoans.list_worker_requests("nope")
    assert {:error, :invalid_request} = DirectWorkerLoans.worker_summary(:bad)
    assert {:error, :invalid_request} = DirectWorkerLoans.list_admin_requests("nope")
    assert {:error, :invalid_request} = DirectWorkerLoans.show_admin_request(admin_id, "nope")
    assert {:error, :invalid_request} = DirectWorkerLoans.list_admin_requests(admin_id, "paid")

    assert {:error, :invalid_amount} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 0})

    assert {:error, :invalid_amount} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => -1})

    assert {:error, :invalid_amount} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => "12.5"})

    assert {:error, :invalid_amount} =
             DirectWorkerLoans.create_request(worker_id, %{amountMinor: 2_147_483_648})

    assert {:error, :invalid_request} =
             DirectWorkerLoans.create_request(worker_id, %{
               "amountMinor" => 1_000,
               "reason" => String.duplicate("a", 501)
             })

    assert {:error, :invalid_request} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 1_000, "reason" => 12})

    assert {:error, :worker_not_found} =
             DirectWorkerLoans.create_request(customer_id, %{"amountMinor" => 1_000})

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{
               "amountMinor" => 1_000,
               "reason" => " "
             })

    assert created["reason"] == nil

    assert {:error, :invalid_decision} =
             DirectWorkerLoans.review(admin_id, created["id"], %{"decision" => "maybe"})

    assert {:error, :invalid_request} =
             DirectWorkerLoans.review(admin_id, created["id"], %{
               "decision" => "approve",
               "reviewNotes" => String.duplicate("n", 501)
             })

    assert {:error, :invalid_request} =
             DirectWorkerLoans.review(admin_id, created["id"], %{
               "decision" => "approve",
               "reviewNotes" => :notes
             })

    assert {:error, :request_not_found} =
             DirectWorkerLoans.show_admin_request(admin_id, Ecto.UUID.generate())

    assert {:error, :request_not_found} =
             DirectWorkerLoans.review(admin_id, Ecto.UUID.generate(), %{"decision" => "reject"})

    assert {:error, :invalid_request} =
             DirectWorkerLoans.review(admin_id, 1, %{"decision" => "reject"})
  end

  test "admin list filters and a second approval after reject" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    other_id = Fixtures.insert_worker!()

    assert {:ok, first} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 2_000})

    assert {:ok, _} =
             DirectWorkerLoans.review(admin_id, first["id"], %{"decision" => "reject"})

    assert {:ok, second} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 4_000})

    assert {:ok, _} =
             DirectWorkerLoans.create_request(other_id, %{"amountMinor" => 7_000})

    assert {:ok, pending} = DirectWorkerLoans.list_admin_requests(admin_id, nil)
    assert length(pending) == 2

    assert {:ok, also_pending} = DirectWorkerLoans.list_admin_requests(admin_id, "")
    assert length(also_pending) == 2

    assert {:ok, rejected} = DirectWorkerLoans.list_admin_requests(admin_id, "rejected")
    assert Enum.map(rejected, & &1["id"]) == [first["id"]]

    assert {:ok, cancelled} = DirectWorkerLoans.list_admin_requests(admin_id, "cancelled")
    assert cancelled == []

    assert {:ok, all} = DirectWorkerLoans.list_admin_requests(admin_id, "all")
    assert length(all) == 3

    assert {:ok, approved} =
             DirectWorkerLoans.review(admin_id, second["id"], %{"decision" => "approve"})

    assert approved["status"] == "approved"

    assert {:error, :request_not_pending} =
             DirectWorkerLoans.review(admin_id, second["id"], %{"decision" => "approve"})

    assert {:ok, [only_approved]} = DirectWorkerLoans.list_admin_requests(admin_id, "approved")
    assert only_approved["id"] == second["id"]
  end

  test "reviewer staff can list but cannot approve" do
    reviewer_id = Fixtures.insert_user!("reviewer")
    worker_id = Fixtures.insert_worker!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 1_500})

    assert {:ok, [_]} = DirectWorkerLoans.list_admin_requests(reviewer_id)

    assert {:error, :forbidden} =
             DirectWorkerLoans.review(reviewer_id, created["id"], %{"decision" => "approve"})
  end

  test "non-owner sessions cannot create or review loans even with actor_id set" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    role = "mithril_loan_probe_#{System.unique_integer([:positive])}"

    Repo.query!("CREATE ROLE #{role} NOLOGIN")
    Repo.query!("SELECT set_config('mithril.actor_id', $1, true)", [worker_id])
    Repo.query!("SET LOCAL SESSION AUTHORIZATION #{role}")

    assert {:error, %Postgrex.Error{postgres: %{message: create_denied}}} =
             Repo.query(
               """
               SELECT public.create_worker_loan_request($1::uuid, $2::integer, $3::text)
               """,
               [Ecto.UUID.dump!(worker_id), 1_000, nil]
             )

    assert create_denied =~ "actor_not_authorized"

    Repo.query!("RESET SESSION AUTHORIZATION")
    Repo.query!("SELECT set_config('mithril.actor_id', $1, true)", [admin_id])
    Repo.query!("SET LOCAL SESSION AUTHORIZATION #{role}")

    assert {:error, %Postgrex.Error{postgres: %{message: review_denied}}} =
             Repo.query(
               """
               SELECT public.review_worker_loan_request($1::uuid, $2::uuid, $3::text, $4::text)
               """,
               [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(admin_id), "approve", nil]
             )

    assert review_denied =~ "reviewer_not_authorized"

    Repo.query!("RESET SESSION AUTHORIZATION")
    Repo.query!("DROP ROLE #{role}")
  end

  test "approval refuses a non-cedi wallet and an overflowing balance" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    worker_uid = Ecto.UUID.dump!(worker_id)

    Repo.query!(
      "INSERT INTO public.wallets (user_id, balance_subunit, currency) VALUES ($1, 0, 'USD')",
      [worker_uid]
    )

    assert {:ok, first} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 100})

    usd =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => first["id"],
        "decision" => "approve"
      })

    assert json_response(usd, 422) == %{"error" => "unsupported_currency"}

    Repo.query!(
      "UPDATE public.wallets SET currency = 'GHS', balance_subunit = 2147483647 WHERE user_id = $1",
      [worker_uid]
    )

    overflow =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => first["id"],
        "decision" => "approve"
      })

    assert json_response(overflow, 422) == %{"error" => "amount_too_large"}
  end

  test "SQL loan writers map remaining database errors" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 900})

    assert {:error, %Postgrex.Error{postgres: %{message: missing}}} =
             DirectAdminActor.with_actor(worker_id, fn ->
               case Repo.query("SELECT public.create_worker_loan_request(NULL, 1, NULL)") do
                 {:ok, result} -> result
                 {:error, error} -> Repo.rollback(error)
               end
             end)

    assert missing =~ "missing_required_fields"

    Repo.query!("DROP FUNCTION public.create_worker_loan_request(uuid, integer, text)")

    assert {:error, :database_unavailable} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 1_000})

    Repo.query!("DROP FUNCTION public.review_worker_loan_request(uuid, uuid, text, text)")

    assert {:error, :database_unavailable} =
             DirectWorkerLoans.review(admin_id, created["id"], %{"decision" => "approve"})
  end

  test "worker and admin HTTP endpoints cover success and error mapping" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    stranger_id = Fixtures.insert_user!()

    create =
      DirectWorkerLoansController.create(worker_conn(worker_id), %{
        "amountMinor" => 6_000,
        "reason" => "Uniforms"
      })

    created = json_response(create, 200)
    assert created["status"] == "pending"
    request_id = created["id"]

    duplicate = DirectWorkerLoansController.create(worker_conn(worker_id), %{"amountMinor" => 1})
    assert json_response(duplicate, 409) == %{"error" => "pending_request_exists"}

    bad_amount = DirectWorkerLoansController.create(worker_conn(worker_id), %{"amountMinor" => 0})
    assert json_response(bad_amount, 422) == %{"error" => "invalid_amount"}

    bad_body = DirectWorkerLoansController.create(worker_conn(worker_id), %{"amountMinor" => "x"})
    assert json_response(bad_body, 422)["error"] in ["invalid_amount", "invalid_request"]

    missing_worker = DirectWorkerLoansController.index(worker_conn(stranger_id), %{})
    assert json_response(missing_worker, 404) == %{"error" => "worker_not_found"}

    forbidden = DirectWorkerLoansController.summary(worker_conn("nope"), %{})
    assert json_response(forbidden, 422) == %{"error" => "invalid_request"}

    index = DirectWorkerLoansController.index(worker_conn(worker_id), %{})
    assert length(json_response(index, 200)["requests"]) == 1

    summary = DirectWorkerLoansController.summary(worker_conn(worker_id), %{})
    assert json_response(summary, 200) == %{"outstandingMinor" => 0, "currency" => "GHS"}

    listed =
      DirectAdminWorkerLoansController.index(staff_conn(admin_id), %{"status" => "pending"})

    assert length(json_response(listed, 200)["requests"]) == 1

    shown = DirectAdminWorkerLoansController.show(staff_conn(admin_id), %{"id" => request_id})
    assert json_response(shown, 200)["id"] == request_id

    bad_decision =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => request_id,
        "decision" => "hold"
      })

    assert json_response(bad_decision, 422) == %{"error" => "invalid_decision"}

    missing =
      DirectAdminWorkerLoansController.show(staff_conn(admin_id), %{
        "id" => Ecto.UUID.generate()
      })

    assert json_response(missing, 404) == %{"error" => "request_not_found"}

    reviewed =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => request_id,
        "decision" => "approve",
        "reviewNotes" => "OK"
      })

    assert json_response(reviewed, 200)["status"] == "approved"

    again =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => request_id,
        "decision" => "reject"
      })

    assert json_response(again, 409) == %{"error" => "request_not_pending"}

    stranger_review =
      DirectAdminWorkerLoansController.index(staff_conn(stranger_id), %{})

    assert json_response(stranger_review, 403) == %{"error" => "forbidden"}

    funded = DirectWorkerLoansController.summary(worker_conn(worker_id), %{})
    assert json_response(funded, 200)["outstandingMinor"] == 6_000

    customer_create =
      DirectWorkerLoansController.create(worker_conn(stranger_id), %{"amountMinor" => 1_000})

    assert json_response(customer_create, 404) == %{"error" => "worker_not_found"}

    bad_status =
      DirectAdminWorkerLoansController.index(staff_conn(admin_id), %{"status" => "paid"})

    assert json_response(bad_status, 422) == %{"error" => "invalid_request"}
  end

  test "HTTP endpoints report a missing database function as unavailable" do
    worker_id = Fixtures.insert_worker!()
    admin_id = Fixtures.insert_user!("admin")

    Repo.query!("DROP FUNCTION public.create_worker_loan_request(uuid, integer, text)")

    create = DirectWorkerLoansController.create(worker_conn(worker_id), %{"amountMinor" => 1_000})
    assert json_response(create, 503) == %{"error" => "database_unavailable"}

    Repo.query!("DROP FUNCTION public.review_worker_loan_request(uuid, uuid, text, text)")

    review =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => Ecto.UUID.generate(),
        "decision" => "approve"
      })

    assert json_response(review, 503) == %{"error" => "database_unavailable"}
  end

  test "HTTP create is forbidden when the database session is not the function owner" do
    worker_id = Fixtures.insert_worker!()
    role = "mithril_loan_http_#{System.unique_integer([:positive])}"

    Repo.query!("CREATE ROLE #{role} NOLOGIN")
    Repo.query!("SET LOCAL SESSION AUTHORIZATION #{role}")

    create =
      DirectWorkerLoansController.create(worker_conn(worker_id), %{"amountMinor" => 1_000})

    assert json_response(create, 403) == %{"error" => "forbidden"}

    Repo.query!("RESET SESSION AUTHORIZATION")
    Repo.query!("DROP ROLE #{role}")
  end

  test "review maps a missing wallet as conflict" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 250})

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.review_worker_loan_request(
      p_request_id uuid,
      p_reviewer_id uuid,
      p_decision text,
      p_review_notes text DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION 'wallet_not_found';
    END
    $function$;
    """)

    review =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => created["id"],
        "decision" => "approve"
      })

    assert json_response(review, 409) == %{"error" => "wallet_not_found"}
  end

  test "listing loans treats a missing cleaner table as worker_not_found" do
    worker_id = Fixtures.insert_worker!()
    Repo.query!("DROP TABLE public.cleaner_data CASCADE")

    assert {:error, :worker_not_found} = DirectWorkerLoans.list_worker_requests(worker_id)
  end

  test "create presents a non-uuid identifier as nil" do
    worker_id = Fixtures.insert_worker!()

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.create_worker_loan_request(
      p_worker_id uuid,
      p_amount_minor integer,
      p_reason text DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      RETURN jsonb_build_object(
        'id', 1,
        'workerId', p_worker_id,
        'amountMinor', p_amount_minor,
        'reason', p_reason,
        'status', 'pending'
      );
    END
    $function$;
    """)

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 1_000})

    assert created["id"] == nil

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.create_worker_loan_request(
      p_worker_id uuid,
      p_amount_minor integer,
      p_reason text DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION 'loan_account_not_found';
    END
    $function$;
    """)

    create = DirectWorkerLoansController.create(worker_conn(worker_id), %{"amountMinor" => 1_000})
    assert json_response(create, 422) == %{"error" => "loan_account_not_found"}
  end

  test "admin HTTP maps an unknown domain atom through the generic error clause" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()

    assert {:ok, created} =
             DirectWorkerLoans.create_request(worker_id, %{"amountMinor" => 400})

    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.review_worker_loan_request(
      p_request_id uuid,
      p_reviewer_id uuid,
      p_decision text,
      p_review_notes text DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION 'loan_account_not_found';
    END
    $function$;
    """)

    review =
      DirectAdminWorkerLoansController.review(staff_conn(admin_id), %{
        "id" => created["id"],
        "decision" => "approve"
      })

    assert json_response(review, 422) == %{"error" => "loan_account_not_found"}
  end

  test "recovery SQL rejects unauthorized and invalid payouts" do
    admin_id = Fixtures.insert_user!("admin")
    worker_id = Fixtures.insert_worker!()
    customer_id = Fixtures.insert_user!()
    booking_id = Fixtures.insert_booking!(customer_id)

    assert {:error, %Postgrex.Error{postgres: %{message: missing}}} =
             recover_query(admin_id, nil, 1_000, booking_id)

    assert missing =~ "missing_required_fields"

    assert {:error, %Postgrex.Error{postgres: %{message: invalid}}} =
             recover_query(admin_id, Ecto.UUID.dump!(worker_id), 0, booking_id)

    assert invalid =~ "invalid_amount"

    assert {:error, %Postgrex.Error{postgres: %{message: not_worker}}} =
             recover_query(admin_id, Ecto.UUID.dump!(customer_id), 1_000, booking_id)

    assert not_worker =~ "worker_not_found"

    role = "mithril_loan_recovery_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE ROLE #{role} NOLOGIN")
    Repo.query!("SELECT set_config('mithril.actor_id', $1, true)", [admin_id])
    Repo.query!("SET LOCAL SESSION AUTHORIZATION #{role}")

    assert {:error, %Postgrex.Error{postgres: %{message: other_role}}} =
             Repo.query(
               """
               SELECT public.apply_worker_loan_recovery(
                 $1::uuid, $2::integer, $3::uuid, 'test', $4::uuid
               )
               """,
               [
                 Ecto.UUID.dump!(worker_id),
                 1_000,
                 Ecto.UUID.dump!(admin_id),
                 Ecto.UUID.dump!(booking_id)
               ]
             )

    assert other_role =~ "recorded_by_not_authorized"

    Repo.query!("RESET SESSION AUTHORIZATION")
    Repo.query!("DROP ROLE #{role}")
  end

  defp recover_loan!(admin_id, worker_uid, amount, booking_id) do
    case recover_query(admin_id, worker_uid, amount, booking_id) do
      {:ok, %{rows: [[payload]]}} -> {:ok, payload}
      other -> other
    end
  end

  defp recover_query(admin_id, worker_uid, amount, booking_id) do
    DirectAdminActor.with_actor(admin_id, fn ->
      case Repo.query(
             """
             SELECT public.apply_worker_loan_recovery(
               $1::uuid, $2::integer, $3::uuid, 'test', $4::uuid
             )
             """,
             [worker_uid, amount, Ecto.UUID.dump!(admin_id), Ecto.UUID.dump!(booking_id)]
           ) do
        {:ok, result} -> result
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  defp worker_conn(user_id), do: Plug.Conn.assign(build_conn(), :instaclean_user_id, user_id)
  defp staff_conn(user_id), do: Plug.Conn.assign(build_conn(), :instaclean_user_id, user_id)
end
