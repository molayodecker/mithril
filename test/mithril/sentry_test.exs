defmodule Mithril.SentryTest do
  use ExUnit.Case, async: true

  defmodule Attempt do
    defstruct attempt: 1, max_attempts: 1
  end

  test "drops probe traces and keeps API traces" do
    assert Mithril.Sentry.traces_sampler(context("/health")) == 0.0
    assert Mithril.Sentry.traces_sampler(context("/ready")) == 0.0
    assert Mithril.Sentry.traces_sampler(context("/metrics")) == 0.0
    assert Mithril.Sentry.traces_sampler(context("/auth/login")) == 1.0
  end

  test "reports an Oban error only on the final attempt" do
    refute Mithril.Sentry.report_oban_error?(nil, %Attempt{attempt: 1, max_attempts: 3})
    assert Mithril.Sentry.report_oban_error?(nil, %Attempt{attempt: 3, max_attempts: 3})
  end

  test "drops webhook signatures and keeps the request id" do
    conn =
      :get
      |> Plug.Test.conn("/webhooks/stripe")
      |> Plug.Conn.put_req_header("authorization", "Bearer secret")
      |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=abc")
      |> Plug.Conn.put_req_header("x-paystack-signature", "paystack")
      |> Plug.Conn.put_req_header("x-twilio-signature", "twilio")
      |> Plug.Conn.put_req_header("x-payload-digest", "sumsub")
      |> Plug.Conn.put_req_header("x-request-id", "req-1")

    headers = Mithril.Sentry.scrub_headers(conn)

    refute Map.has_key?(headers, "authorization")
    refute Map.has_key?(headers, "stripe-signature")
    refute Map.has_key?(headers, "x-paystack-signature")
    refute Map.has_key?(headers, "x-twilio-signature")
    refute Map.has_key?(headers, "x-payload-digest")
    assert headers["x-request-id"] == "req-1"
  end

  test "redacts database URLs and sensitive query parameters on traces" do
    span = %Sentry.Interfaces.Span{
      trace_id: String.duplicate("a", 32),
      span_id: String.duplicate("b", 16),
      start_timestamp: 0,
      timestamp: 1,
      data: %{
        "url.query" => "otp=123456&page=2",
        "db.url" => "postgres://mithril:secret-password@db.internal:5432/mithril"
      }
    }

    transaction = %Sentry.Transaction{
      event_id: String.duplicate("c", 32),
      span_id: String.duplicate("d", 16),
      start_timestamp: 0,
      timestamp: 1,
      contexts: %{trace: %{data: span.data}},
      spans: [span]
    }

    scrubbed = Mithril.Sentry.before_send(transaction)

    assert scrubbed.contexts.trace.data["url.query"] ==
             "otp=#{Sentry.Scrubber.scrubbed_value()}&page=2"

    assert scrubbed.contexts.trace.data["db.url"] == "redacted"
    assert hd(scrubbed.spans).data["db.url"] == "redacted"
    refute hd(scrubbed.spans).data["url.query"] =~ "123456"
  end

  defp context(path) do
    %{transaction_context: %{attributes: %{"url.path" => path}}}
  end
end
