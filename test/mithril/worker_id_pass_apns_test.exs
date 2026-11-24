defmodule Mithril.WorkerIdPassApnsTest do
  use ExUnit.Case, async: false

  @env_names ~w(
    APPLE_PASS_CERTIFICATE_PATH
    APPLE_PASS_KEY_PATH
    APPLE_PASS_KEY_PASSPHRASE
    APPLE_PASS_APNS_KEY_PATH
    APPLE_PASS_APNS_KEY_ID
    APPLE_PASS_TYPE_IDENTIFIER
  )

  setup do
    previous = Map.new(@env_names, &{&1, System.get_env(&1)})
    Enum.each(@env_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "the pass certificate authenticates an installed pass refresh" do
    directory = Path.join(System.tmp_dir!(), "wallet-apns-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    certificate = Path.join(directory, "pass.pem")
    key = Path.join(directory, "pass.key")

    File.write!(certificate, """
    -----BEGIN CERTIFICATE-----
    MIIB
    -----END CERTIFICATE-----
    """)

    File.write!(key, """
    -----BEGIN PRIVATE KEY-----
    MIIB
    -----END PRIVATE KEY-----
    """)

    System.put_env("APPLE_PASS_CERTIFICATE_PATH", certificate)
    System.put_env("APPLE_PASS_KEY_PATH", key)
    System.put_env("APPLE_PASS_KEY_PASSPHRASE", "wallet-test-passphrase")
    System.put_env("APPLE_PASS_APNS_KEY_PATH", Path.join(directory, "missing-apns.p8"))
    System.put_env("APPLE_PASS_APNS_KEY_ID", "AAAAAAAAAA")

    assert Mithril.WorkerIdPass.apns_auth() == :certificate

    headers = Mithril.WorkerIdPass.apns_headers(:certificate)
    assert {"apns-topic", "pass.com.tryinstaclean.workerid"} in headers
    assert {"apns-push-type", "background"} in headers
    assert {"apns-priority", "5"} in headers
    refute Enum.any?(headers, fn {name, _value} -> name == "authorization" end)

    transport_opts = Mithril.WorkerIdPass.apns_transport_opts()
    assert transport_opts[:certfile] == String.to_charlist(certificate)
    assert transport_opts[:keyfile] == String.to_charlist(key)
    assert transport_opts[:password] == ~c"wallet-test-passphrase"

    pool = Mithril.WorkerIdPass.apns_pool_config()
    assert pool[:protocols] == [:http2]
    assert pool[:conn_opts][:transport_opts] == transport_opts
  end

  test "PEM text in the pass certificate variables is written before the push connection opens" do
    System.put_env(
      "APPLE_PASS_CERTIFICATE_PATH",
      "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
    )

    System.put_env(
      "APPLE_PASS_KEY_PATH",
      "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----"
    )

    assert Mithril.WorkerIdPass.apns_auth() == :certificate
    transport_opts = Mithril.WorkerIdPass.apns_transport_opts()
    assert File.regular?(to_string(transport_opts[:certfile]))
    assert File.regular?(to_string(transport_opts[:keyfile]))
    refute Keyword.has_key?(transport_opts, :password)
  end

  test "an update push stays unconfigured when the pass certificate is absent" do
    System.put_env(
      "APPLE_PASS_APNS_KEY_PATH",
      Path.join(System.tmp_dir!(), "missing-apns-#{System.unique_integer([:positive])}.p8")
    )

    System.put_env("APPLE_PASS_APNS_KEY_ID", "AAAAAAAAAA")

    assert Mithril.WorkerIdPass.apns_auth() == :unconfigured
    assert Mithril.WorkerIdPass.apns_transport_opts() == []
    refute Keyword.has_key?(Mithril.WorkerIdPass.apns_pool_config(), :conn_opts)
  end
end
