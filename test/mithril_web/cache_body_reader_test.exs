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

  test "only caches raw bodies for signed webhook paths" do
    body = ~s({"ok":true})

    paystack = %Plug.Conn{
      adapter: {__MODULE__.OkAdapter, body},
      path_info: ["webhooks", "paystack"]
    }

    sumsub = %Plug.Conn{
      adapter: {__MODULE__.OkAdapter, body},
      path_info: ["webhooks", "sumsub"]
    }

    other = %Plug.Conn{adapter: {__MODULE__.OkAdapter, body}, path_info: ["health"]}

    assert {:ok, ^body, cached_paystack} = CacheBodyReader.read_body(paystack, [])
    assert CacheBodyReader.body(cached_paystack) == body

    assert {:ok, ^body, cached_sumsub} = CacheBodyReader.read_body(sumsub, [])
    assert CacheBodyReader.body(cached_sumsub) == body

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
