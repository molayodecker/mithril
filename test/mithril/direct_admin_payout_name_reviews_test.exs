defmodule Mithril.DirectAdminPayoutNameReviewsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Mithril.DirectAdminPayoutNameReviews
  alias Mithril.Repo

  setup do
    :ok = Sandbox.checkout(Repo)

    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to recreate review fixtures; expected mithril_test, got #{inspect(database)}"
    end

    for table <- ["payout_name_reviews", "user_roles", "profiles", "users"] do
      Repo.query!("DROP TABLE IF EXISTS public.#{table} CASCADE")
    end

    Repo.query!("""
    CREATE TABLE public.users (
      id uuid PRIMARY KEY,
      email text
    )
    """)

    Repo.query!("""
    CREATE TABLE public.profiles (
      id uuid PRIMARY KEY,
      fullname text,
      firstname text,
      lastname text,
      preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE public.user_roles (
      user_id uuid NOT NULL,
      role_id text NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE public.payout_name_reviews (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL,
      purpose text NOT NULL,
      payout_type text NOT NULL,
      profile_name text,
      account_name text,
      submitted_name text,
      names_match boolean NOT NULL,
      status text NOT NULL,
      bank_code text,
      account_number text NOT NULL,
      review_notes text,
      reviewed_by uuid,
      reviewed_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX payout_name_reviews_one_pending_idx
      ON public.payout_name_reviews (user_id, purpose, account_number)
      WHERE status = 'pending'
    """)

    admin_id = Ecto.UUID.generate()
    worker_id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.users (id, email) VALUES ($1, $2), ($3, $4)", [
      Ecto.UUID.dump!(admin_id),
      "ops@tryinstaclean.com",
      Ecto.UUID.dump!(worker_id),
      "worker@example.com"
    ])

    Repo.query!(
      "INSERT INTO public.profiles (id, fullname) VALUES ($1, $2), ($3, $4)",
      [Ecto.UUID.dump!(admin_id), "Ops Lead", Ecto.UUID.dump!(worker_id), "Ama Serwaa"]
    )

    Repo.query!("INSERT INTO public.user_roles (user_id, role_id) VALUES ($1, 'admin')", [
      Ecto.UUID.dump!(admin_id)
    ])

    {:ok, admin_id: admin_id, worker_id: worker_id}
  end

  test "a mismatched name notifies admin once and stays pending", %{
    admin_id: admin_id,
    worker_id: worker_id
  } do
    parent = self()

    notify = fn message ->
      send(parent, {:admin_notice, message})
      %{email_sent: true, sms_sent: 0, slack_sent: false, sms_skipped: true}
    end

    attrs = %{
      purpose: "payout",
      payout_type: "mobile_money",
      submitted_name: "Ama Serwaa",
      account_name: "MENSAH BOATENG",
      bank_code: "MTN",
      account_number: "0240000000",
      notify: notify
    }

    assert {:ok, first} = DirectAdminPayoutNameReviews.open(worker_id, attrs)
    assert first.names_match == false
    assert first.notified == true
    assert_receive {:admin_notice, message}
    assert message.subject =~ "Payout name mismatch"
    assert message.plain_body =~ "Ama Serwaa"
    assert message.plain_body =~ "MENSAH BOATENG"
    assert message.plain_body =~ "Direct"
    refute message.plain_body =~ "0240000000"

    assert {:ok, second} = DirectAdminPayoutNameReviews.open(worker_id, attrs)
    assert second.id == first.id
    assert second.notified == false
    refute_receive {:admin_notice, _}, 50

    assert {:ok, reviews} = DirectAdminPayoutNameReviews.list(admin_id)
    assert length(reviews) == 1
    review = hd(reviews)
    assert review["namesMatch"] == false
    assert review["maskedAccount"] == "•••• 0000"
    refute Map.has_key?(review, "accountNumber")

    [[preferences]] =
      Repo.query!("SELECT preferences FROM public.profiles WHERE id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    assert preferences["payout_name_mismatch"]["payout_account_name"] == "MENSAH BOATENG"
  end

  test "a matching name is held without an admin notice", %{worker_id: worker_id} do
    parent = self()

    notify = fn message ->
      send(parent, {:admin_notice, message})
      %{email_sent: true, sms_sent: 0, slack_sent: false, sms_skipped: true}
    end

    assert {:ok, review} =
             DirectAdminPayoutNameReviews.open(worker_id, %{
               purpose: "payout",
               payout_type: "mobile_money",
               submitted_name: "Ama Serwaa",
               account_name: "Serwaa Ama",
               bank_code: "MTN",
               account_number: "0240000001",
               notify: notify
             })

    assert review.names_match == true
    assert review.notified == false
    refute_receive {:admin_notice, _}, 50
  end

  test "an admin can approve the review and clear the hold flag", %{
    admin_id: admin_id,
    worker_id: worker_id
  } do
    assert {:ok, opened} =
             DirectAdminPayoutNameReviews.open(worker_id, %{
               purpose: "payout",
               payout_type: "mobile_money",
               submitted_name: "Ama Serwaa",
               account_name: "MENSAH BOATENG",
               bank_code: "MTN",
               account_number: "0240000002",
               notify: fn _ ->
                 %{email_sent: false, sms_sent: 0, slack_sent: false, sms_skipped: true}
               end
             })

    assert {:ok, decision} =
             DirectAdminPayoutNameReviews.review(admin_id, opened.id, %{"decision" => "approve"})

    assert decision["status"] == "approved"
    assert decision["recipientCreated"] == false

    assert {:error, :review_not_pending} =
             DirectAdminPayoutNameReviews.review(admin_id, opened.id, %{"decision" => "reject"})

    [[preferences]] =
      Repo.query!("SELECT preferences FROM public.profiles WHERE id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    refute Map.has_key?(preferences, "payout_name_mismatch")
  end

  test "approving one account preserves another unresolved account flag", %{
    admin_id: admin_id,
    worker_id: worker_id
  } do
    attrs = %{
      purpose: "payout",
      payout_type: "mobile_money",
      submitted_name: "Ama Serwaa",
      account_name: "FIRST MISMATCH",
      bank_code: "MTN",
      account_number: "0240000011",
      notify: fn _ -> %{email_sent: false, sms_sent: 0, slack_sent: false, sms_skipped: true} end
    }

    assert {:ok, first} = DirectAdminPayoutNameReviews.open(worker_id, attrs)

    assert {:ok, second} =
             DirectAdminPayoutNameReviews.open(
               worker_id,
               %{attrs | account_name: "SECOND MISMATCH", account_number: "0240000012"}
             )

    assert {:ok, %{"status" => "approved"}} =
             DirectAdminPayoutNameReviews.review(admin_id, first.id, %{"decision" => "approve"})

    [[preferences]] =
      Repo.query!("SELECT preferences FROM public.profiles WHERE id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    assert preferences["payout_name_mismatch"]["payout_account_name"] == "SECOND MISMATCH"

    assert {:ok, %{"status" => "rejected"}} =
             DirectAdminPayoutNameReviews.review(admin_id, second.id, %{"decision" => "reject"})

    [[after_rejection]] =
      Repo.query!("SELECT preferences FROM public.profiles WHERE id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    assert after_rejection["payout_name_mismatch"]["payout_account_name"] ==
             "SECOND MISMATCH"
  end

  test "payout and refund holds preserve both purpose flags", %{worker_id: worker_id} do
    attrs = %{
      payout_type: "bank",
      submitted_name: "Ama Serwaa",
      account_name: "UNKNOWN OWNER",
      bank_code: "GH",
      account_number: "10001122",
      notify: fn _ -> %{email_sent: false, sms_sent: 0, slack_sent: false, sms_skipped: true} end
    }

    assert {:ok, _} =
             DirectAdminPayoutNameReviews.open(worker_id, Map.put(attrs, :purpose, "payout"))

    assert {:ok, _} =
             DirectAdminPayoutNameReviews.open(worker_id, Map.put(attrs, :purpose, "refund"))

    [[preferences]] =
      Repo.query!("SELECT preferences FROM public.profiles WHERE id = $1", [
        Ecto.UUID.dump!(worker_id)
      ]).rows

    assert preferences["payout_name_mismatches"]["payout"]["payout_account_name"] ==
             "UNKNOWN OWNER"

    assert preferences["payout_name_mismatches"]["refund"]["payout_account_name"] ==
             "UNKNOWN OWNER"
  end

  test "a guest cannot list reviews", %{worker_id: worker_id} do
    assert {:error, :forbidden} = DirectAdminPayoutNameReviews.list(worker_id)
  end

  test "a profile mismatch flag appears in the pending queue", %{
    admin_id: admin_id,
    worker_id: worker_id
  } do
    sql =
      "priv/repo/sql/direct/20261109170000_enqueue_payout_name_reviews_from_flags.sql"
      |> File.read!()

    execute_sql_script(sql)

    flag =
      Jason.encode!(%{
        "flagged_at" => "2026-11-08 04:19:59",
        "profile_name" => "cwztle bkfvvp",
        "payout_account_name" => "SAMUEL AMENUME",
        "payout_type" => "mobile_money",
        "requires_review" => true,
        "source" => "payout_name_mismatch"
      })

    Repo.query!(
      "UPDATE public.profiles SET preferences = jsonb_build_object('payout_name_mismatch', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(worker_id), flag]
    )

    assert {:ok, [review]} = DirectAdminPayoutNameReviews.list(admin_id)
    assert review["profileName"] == "cwztle bkfvvp"
    assert review["accountName"] == "SAMUEL AMENUME"
    assert review["namesMatch"] == false
    assert review["status"] == "pending"

    Repo.query!(
      "UPDATE public.profiles SET preferences = jsonb_build_object('payout_name_mismatch', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(worker_id), flag]
    )

    assert {:ok, [_]} = DirectAdminPayoutNameReviews.list(admin_id)

    assert {:ok, _} =
             DirectAdminPayoutNameReviews.review(admin_id, review["id"], %{"decision" => "reject"})

    assert {:ok, []} = DirectAdminPayoutNameReviews.list(admin_id)

    assert {:ok, [closed]} =
             DirectAdminPayoutNameReviews.list(admin_id, %{"status" => "rejected"})

    assert closed["id"] == review["id"]
  end

  test "backfill reuses an existing pending review with an account number", %{
    admin_id: admin_id,
    worker_id: worker_id
  } do
    assert {:ok, opened} =
             DirectAdminPayoutNameReviews.open(worker_id, %{
               purpose: "payout",
               payout_type: "mobile_money",
               submitted_name: "Ama Serwaa",
               account_name: "ANOTHER NAME",
               bank_code: "MTN",
               account_number: "0240000066",
               notify: fn _ ->
                 %{email_sent: false, sms_sent: 0, slack_sent: false, sms_skipped: true}
               end
             })

    execute_sql_script(
      File.read!("priv/repo/sql/direct/20261109170000_enqueue_payout_name_reviews_from_flags.sql")
    )

    assert {:ok, [review]} = DirectAdminPayoutNameReviews.list(admin_id)
    assert review["id"] == opened.id
    assert review["maskedAccount"] == "•••• 0066"

    assert {:ok, %{"status" => "approved"}} =
             DirectAdminPayoutNameReviews.review(admin_id, opened.id, %{"decision" => "approve"})

    assert {:ok, []} = DirectAdminPayoutNameReviews.list(admin_id)
  end

  test "a rejected mismatch is not reopened on unrelated preference updates or backfill", %{
    admin_id: admin_id,
    worker_id: worker_id
  } do
    sql =
      File.read!("priv/repo/sql/direct/20261109170000_enqueue_payout_name_reviews_from_flags.sql")
    execute_sql_script(sql)

    flag =
      Jason.encode!(%{
        "profile_name" => "Ama Serwaa",
        "payout_account_name" => "ANOTHER NAME",
        "payout_type" => "mobile_money",
        "flagged_at" => "2026-11-09T12:00:00Z"
      })

    Repo.query!(
      "UPDATE public.profiles SET preferences = jsonb_build_object('payout_name_mismatch', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(worker_id), flag]
    )

    assert {:ok, [review]} = DirectAdminPayoutNameReviews.list(admin_id)

    assert {:ok, %{"status" => "rejected"}} =
             DirectAdminPayoutNameReviews.review(admin_id, review["id"], %{"decision" => "reject"})

    # Simulate a new request transaction after the admin's suppression guard.
    Repo.query!("SELECT set_config('mithril.payout_name_review_sync', 'off', true)")

    Repo.query!(
      "UPDATE public.profiles SET preferences = preferences || '{\"theme\": \"dark\"}'::jsonb WHERE id = $1",
      [Ecto.UUID.dump!(worker_id)]
    )

    assert {:ok, []} = DirectAdminPayoutNameReviews.list(admin_id)
    execute_sql_script(sql)
    assert {:ok, []} = DirectAdminPayoutNameReviews.list(admin_id)
  end

  test "reordered equivalent names never create a pending review", %{
    admin_id: admin_id,
    worker_id: worker_id
  } do
    execute_sql_script(
      File.read!("priv/repo/sql/direct/20261109170000_enqueue_payout_name_reviews_from_flags.sql")
    )

    flag =
      Jason.encode!(%{
        "profile_name" => "Ama Serwaa",
        "payout_account_name" => "SERWAA AMA",
        "payout_type" => "mobile_money"
      })

    Repo.query!(
      "UPDATE public.profiles SET preferences = jsonb_build_object('payout_name_mismatch', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(worker_id), flag]
    )

    assert {:ok, []} = DirectAdminPayoutNameReviews.list(admin_id)
  end

  defp execute_sql_script(sql) do
    sql
    |> sql_statements()
    |> Enum.each(&Repo.query!/1)
  end

  defp sql_statements(sql) do
    sql
    |> strip_sql_comments()
    |> split_sql([], [])
    |> Enum.reverse()
  end

  defp strip_sql_comments(sql) do
    sql
    |> String.split("\n")
    |> Enum.map(fn line ->
      case String.split(line, "--", parts: 2) do
        [code, _comment] -> code
        [code] -> code
      end
    end)
    |> Enum.join("\n")
  end

  defp split_sql(<<>>, statements, current) do
    push_statement(statements, current)
  end

  defp split_sql(<<";", rest::binary>>, statements, current) do
    split_sql(rest, push_statement(statements, current), [])
  end

  defp split_sql(<<"$", rest::binary>>, statements, current) do
    {marker, after_open} = dollar_marker(rest)
    {body, after_body} = take_until(after_open, marker)
    split_sql(after_body, statements, current ++ [marker, body, marker])
  end

  defp split_sql(<<char::utf8, rest::binary>>, statements, current) do
    split_sql(rest, statements, current ++ [<<char::utf8>>])
  end

  defp dollar_marker(rest) do
    case Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*)?\$/, rest) do
      [full, tag] -> {"$" <> tag <> "$", String.replace_prefix(rest, full, "")}
      [full] -> {"$$", String.replace_prefix(rest, full, "")}
    end
  end

  defp take_until(sql, marker) do
    size = byte_size(marker)

    case :binary.match(sql, marker) do
      {index, ^size} ->
        {binary_part(sql, 0, index),
         binary_part(sql, index + size, byte_size(sql) - index - size)}

      :nomatch ->
        {sql, <<>>}
    end
  end

  defp push_statement(statements, current) do
    statement = current |> IO.iodata_to_binary() |> String.trim()
    if statement == "", do: statements, else: [statement | statements]
  end
end
