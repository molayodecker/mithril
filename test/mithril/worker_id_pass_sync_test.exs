defmodule Mithril.WorkerIdPassSyncTest do
  use ExUnit.Case, async: false

  alias Mithril.Repo
  alias Mithril.WorkerIdPass
  alias Mithril.WorkerIdPass.PushListener
  alias Mithril.Workers.WorkerIdPassPushSweep

  @device "wallet-device-1"
  @pass_type "pass.test.worker"
  @role "wallet_status_writer"

  setup_all do
    case admin_query!("SELECT 1 FROM pg_roles WHERE rolname = '#{@role}'").rows do
      [[1]] -> :ok
      [] -> admin_query!("CREATE ROLE #{@role} NOINHERIT")
    end

    on_exit(fn ->
      admin_query!("DROP OWNED BY #{@role}")
      admin_query!("DROP ROLE IF EXISTS #{@role}")
    end)

    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    [[database]] = Repo.query!("SELECT current_database()").rows

    unless database == "mithril_test" do
      raise "Refusing to install wallet triggers; expected mithril_test, got #{inspect(database)}"
    end

    install_base_tables!()
    install_wallet_sql!()
    :ok
  end

  test "suspending the cleaner voids the installed pass and advances the phone cursor" do
    worker = insert_installed_pass!()
    other = insert_installed_pass!()
    since = max(cursor(worker.updated_at), cursor(other.updated_at))

    assert WorkerIdPass.serials(@device, @pass_type, Integer.to_string(since)) == :none

    Repo.query!("UPDATE public.cleaner_data SET status = 'suspended' WHERE user_id = $1", [
      dump!(worker.user_id)
    ])

    suspended = fetch!(worker.user_id)
    assert suspended.voided
    assert suspended.push_pending
    assert cursor(suspended.updated_at) > since

    assert {:ok, %{"lastUpdated" => last, "serialNumbers" => [serial]}} =
             WorkerIdPass.serials(@device, @pass_type, Integer.to_string(since))

    assert serial == worker.serial
    assert String.to_integer(last) == cursor(suspended.updated_at)

    untouched = fetch!(other.user_id)
    assert untouched.voided == false
    assert untouched.push_pending == false
    assert cursor(untouched.updated_at) == cursor(other.updated_at)

    assert trigger_definer?("queue_cleaner_worker_id_status_refresh")
    assert function_notifies?("queue_cleaner_worker_id_status_refresh")
  end

  test "suspending the account voids the pass while the cleaner row stays active" do
    worker = insert_installed_pass!()

    Repo.query!("UPDATE public.users SET status = 'suspended' WHERE id = $1", [
      dump!(worker.user_id)
    ])

    suspended = fetch!(worker.user_id)
    assert suspended.voided
    assert suspended.push_pending
    assert cursor(suspended.updated_at) > cursor(worker.updated_at)
    assert trigger_definer?("queue_worker_id_status_refresh")
    assert function_notifies?("queue_worker_id_status_refresh")
  end

  test "the pass stays voided until both the account and the cleaner are active again" do
    worker = insert_installed_pass!()

    Repo.query!("UPDATE public.cleaner_data SET status = 'suspended' WHERE user_id = $1", [
      dump!(worker.user_id)
    ])

    Repo.query!("UPDATE public.users SET status = 'suspended' WHERE id = $1", [
      dump!(worker.user_id)
    ])

    both = fetch!(worker.user_id)
    assert both.voided

    Repo.query!("UPDATE public.users SET status = 'active' WHERE id = $1", [dump!(worker.user_id)])

    still_suspended = fetch!(worker.user_id)
    assert still_suspended.voided
    assert cursor(still_suspended.updated_at) > cursor(both.updated_at)

    Repo.query!("UPDATE public.cleaner_data SET status = 'active' WHERE user_id = $1", [
      dump!(worker.user_id)
    ])

    restored = fetch!(worker.user_id)
    refute restored.voided
    assert restored.push_pending
    assert cursor(restored.updated_at) > cursor(still_suspended.updated_at)
  end

  test "repeating the current status or editing another column does not refresh the pass" do
    worker = insert_installed_pass!()
    before = fetch!(worker.user_id)

    Repo.query!("UPDATE public.cleaner_data SET status = 'active' WHERE user_id = $1", [
      dump!(worker.user_id)
    ])

    Repo.query!("UPDATE public.cleaner_data SET verified = true WHERE user_id = $1", [
      dump!(worker.user_id)
    ])

    Repo.query!("UPDATE public.users SET email = 'worker@example.com' WHERE id = $1", [
      dump!(worker.user_id)
    ])

    after_update = fetch!(worker.user_id)
    assert after_update.voided == before.voided
    assert after_update.push_pending == before.push_pending
    assert cursor(after_update.updated_at) == cursor(before.updated_at)
  end

  test "a failed refresh stays pending until Apple accepts it or no phone is registered" do
    worker = insert_installed_pass!()

    Repo.query!("UPDATE public.users SET status = 'suspended' WHERE id = $1", [
      dump!(worker.user_id)
    ])

    without_apns(fn ->
      assert :ok = WorkerIdPassPushSweep.perform(%Oban.Job{})
    end)

    pending = fetch!(worker.user_id)
    assert pending.push_pending
    assert pending.voided

    stale = DateTime.add(pending.updated_at, -1, :microsecond)

    assert {:ok, %{num_rows: 0}} =
             Repo.query(
               """
               UPDATE public.worker_id_passes
               SET push_pending = false
               WHERE serial_number = $1 AND updated_at = $2
               """,
               [worker.serial, stale]
             )

    assert fetch!(worker.user_id).push_pending

    ref = make_ref()
    state = %{notifications: nil, ref: ref, retry_ms: 1}

    without_apns(fn ->
      assert {:noreply, ^state} =
               PushListener.handle_info(
                 {:notification, self(), ref, PushListener.channel(), ""},
                 state
               )
    end)

    assert fetch!(worker.user_id).push_pending

    Repo.query!("DELETE FROM public.worker_id_pass_registrations WHERE serial_number = $1", [
      worker.serial
    ])

    without_apns(fn ->
      assert :ok = WorkerIdPass.flush_pending_pushes()
    end)

    refute fetch!(worker.user_id).push_pending
  end

  test "a writer who cannot update the pass table still queues the refresh" do
    worker = insert_installed_pass!()

    Repo.query!("GRANT SELECT, UPDATE ON public.cleaner_data TO #{@role}")
    Repo.query!("GRANT SELECT, UPDATE ON public.users TO #{@role}")

    Repo.query!("SET LOCAL ROLE #{@role}")

    Repo.query!("UPDATE public.cleaner_data SET status = 'suspended' WHERE user_id = $1", [
      dump!(worker.user_id)
    ])

    Repo.query!("RESET ROLE")

    suspended = fetch!(worker.user_id)
    assert suspended.voided
    assert suspended.push_pending
    assert cursor(suspended.updated_at) > cursor(worker.updated_at)
  end

  defp admin_query!(sql) do
    opts =
      Mithril.Repo.config()
      |> Keyword.take([
        :hostname,
        :port,
        :database,
        :username,
        :password,
        :ssl,
        :socket,
        :socket_options,
        :parameters
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.put(:sync_connect, true)

    {:ok, pid} = Postgrex.start_link(opts)

    try do
      Postgrex.query!(pid, sql, [])
    after
      GenServer.stop(pid)
    end
  end

  defp install_base_tables! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.users (
      id uuid PRIMARY KEY,
      email text,
      status text NOT NULL DEFAULT 'active'
    )
    """)

    Repo.query!("""
    ALTER TABLE public.users
      ADD COLUMN IF NOT EXISTS email text,
      ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active'
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.cleaner_data (
      user_id uuid PRIMARY KEY,
      status text NOT NULL DEFAULT 'active',
      verified boolean NOT NULL DEFAULT false
    )
    """)

    Repo.query!("""
    ALTER TABLE public.cleaner_data
      ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',
      ADD COLUMN IF NOT EXISTS verified boolean NOT NULL DEFAULT false
    """)
  end

  defp install_wallet_sql! do
    path =
      Path.expand("../../priv/repo/sql/direct/20261120110000_worker_id_passes.sql", __DIR__)

    for statement <- sql_statements(File.read!(path)) do
      Repo.query!(statement)
    end
  end

  defp insert_installed_pass! do
    user_id = Ecto.UUID.generate()
    serial = "worker-" <> String.replace(user_id, "-", "")

    Repo.query!("INSERT INTO public.users (id, status) VALUES ($1, 'active')", [dump!(user_id)])

    Repo.query!("INSERT INTO public.cleaner_data (user_id, status) VALUES ($1, 'active')", [
      dump!(user_id)
    ])

    %{rows: [[updated_at]]} =
      Repo.query!(
        """
        INSERT INTO public.worker_id_passes
          (user_id, serial_number, authentication_token, voided, push_pending)
        VALUES ($1, $2, $3, false, false)
        RETURNING updated_at
        """,
        [dump!(user_id), serial, Ecto.UUID.generate()]
      )

    Repo.query!(
      """
      INSERT INTO public.worker_id_pass_registrations
        (device_library_identifier, pass_type_identifier, serial_number, push_token)
      VALUES ($1, $2, $3, $4)
      """,
      [@device, @pass_type, serial, "push-" <> serial]
    )

    %{user_id: user_id, serial: serial, updated_at: updated_at}
  end

  defp fetch!(user_id) do
    %{rows: [[voided, push_pending, updated_at]]} =
      Repo.query!(
        """
        SELECT voided, push_pending, updated_at
        FROM public.worker_id_passes
        WHERE user_id = $1
        """,
        [dump!(user_id)]
      )

    %{voided: voided, push_pending: push_pending, updated_at: updated_at}
  end

  defp trigger_definer?(name) do
    %{rows: [[true, config]]} =
      Repo.query!(
        """
        SELECT prosecdef, proconfig
        FROM pg_proc
        WHERE proname = $1
        """,
        [name]
      )

    Enum.any?(config || [], &String.contains?(&1, "search_path=public"))
  end

  defp function_notifies?(name) do
    %{rows: [[source]]} =
      Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = $1", [name])

    source =~ "pg_notify('#{PushListener.channel()}'"
  end

  defp cursor(value), do: WorkerIdPass.cursor_microseconds(value)

  defp without_apns(fun) do
    names = ~w(
      APPLE_PASS_APNS_KEY_PATH
      APPLE_PASS_APNS_KEY_ID
      APPLE_PASS_CERTIFICATE_PATH
      APPLE_PASS_KEY_PATH
      APPLE_PASS_KEY_PASSPHRASE
    )

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp dump!(id), do: Ecto.UUID.dump!(id)

  defp sql_statements(sql), do: sql_statements(sql, :code, "", [])

  defp sql_statements(<<>>, :code, current, acc), do: finish_statement(current, acc)

  defp sql_statements(<<"--", rest::binary>>, :code, current, acc) do
    {line, rest} = take_until_newline(rest)
    sql_statements(rest, :code, current <> "--" <> line, acc)
  end

  defp sql_statements(<<"'", rest::binary>>, :code, current, acc) do
    {literal, rest} = take_string(rest, "'")
    sql_statements(rest, :code, current <> literal, acc)
  end

  defp sql_statements(<<"$", rest::binary>>, :code, current, acc) do
    case take_dollar_tag(rest, "") do
      {:ok, tag, rest} ->
        closer = "$" <> tag <> "$"
        {body, rest} = take_until(rest, closer)
        sql_statements(rest, :code, current <> closer <> body <> closer, acc)

      :error ->
        <<char, rest::binary>> = "$" <> rest
        sql_statements(rest, :code, current <> <<char>>, acc)
    end
  end

  defp sql_statements(<<";", rest::binary>>, :code, current, acc) do
    sql_statements(rest, :code, "", finish_statement(current, acc))
  end

  defp sql_statements(<<char, rest::binary>>, :code, current, acc) do
    sql_statements(rest, :code, current <> <<char>>, acc)
  end

  defp finish_statement(current, acc) do
    statement =
      current
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "--")))
      |> Enum.join("\n")
      |> String.trim()

    if statement == "", do: acc, else: acc ++ [statement]
  end

  defp take_until_newline(rest) do
    case String.split(rest, "\n", parts: 2) do
      [line, rest] -> {line <> "\n", rest}
      [line] -> {line, ""}
    end
  end

  defp take_string(<<"''", rest::binary>>, acc), do: take_string(rest, acc <> "''")
  defp take_string(<<"'", rest::binary>>, acc), do: {acc <> "'", rest}
  defp take_string(<<char, rest::binary>>, acc), do: take_string(rest, acc <> <<char>>)
  defp take_string(<<>>, acc), do: {acc, ""}

  defp take_dollar_tag(<<"$", rest::binary>>, tag), do: {:ok, tag, rest}

  defp take_dollar_tag(<<char, rest::binary>>, tag)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_ do
    take_dollar_tag(rest, tag <> <<char>>)
  end

  defp take_dollar_tag(_rest, _tag), do: :error

  defp take_until(rest, marker) do
    size = byte_size(marker)

    cond do
      rest == "" ->
        {"", ""}

      String.starts_with?(rest, marker) ->
        {"", binary_part(rest, size, byte_size(rest) - size)}

      true ->
        <<char, next::binary>> = rest
        {body, rest} = take_until(next, marker)
        {<<char>> <> body, rest}
    end
  end
end
