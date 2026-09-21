defmodule MithrilWeb.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  alias MithrilWeb.CacheBodyReader

  test "forwards read errors instead of raising MatchError" do
    conn = %Plug.Conn{
      adapter: {__MODULE__.ErrorAdapter, :timeout},
      path_info: ["webhooks", "paystack"]
    }

    assert {:error, :timeout} = CacheBodyReader.read_body(conn, [])
  end

  test "caches the raw body for Paystack webhook paths" do
    body = ~s({"ok":true})

    paystack = %Plug.Conn{
      adapter: {__MODULE__.OkAdapter, body},
      path_info: ["webhooks", "paystack"]
    }

    other = %Plug.Conn{adapter: {__MODULE__.OkAdapter, body}, path_info: ["health"]}

    assert {:ok, ^body, cached} = CacheBodyReader.read_body(paystack, [])
    assert CacheBodyReader.body(cached) == body

    assert {:ok, ^body, uncached} = CacheBodyReader.read_body(other, [])
    assert CacheBodyReader.body(uncached) == ""
  end

  defmodule OkAdapter do
    def read_req_body(body, _opts), do: {:ok, body, body}
  end

  defmodule ErrorAdapter do
    def read_req_body(reason, _opts), do: {:error, reason}
  end
end
