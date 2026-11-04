defmodule Mithril.Sentry do
  @moduledoc false

  @ignored_paths ["/health", "/ready", "/metrics"]
  @webhook_headers ~w(
    stripe-signature
    x-paystack-signature
    x-twilio-signature
    x-payload-digest
  )

  @doc """
  Samples every trace except the probes Fly and the metrics scraper call continuously.
  """
  def traces_sampler(%{transaction_context: %{attributes: attributes}}) do
    if path_from_attributes(attributes) in @ignored_paths, do: 0.0, else: 1.0
  end

  def traces_sampler(_sampling_context), do: 1.0

  @doc """
  Reports an Oban failure once retries are exhausted.

  Oban wraps both crashes and ordinary `{:error, reason}` results. Intermediate
  attempts are retries, so only the final attempt becomes a Sentry issue.
  """
  def report_oban_error?(_worker, job) do
    job.attempt >= job.max_attempts
  end

  @doc """
  Drops webhook signatures on top of Sentry's default header scrubber.
  """
  def scrub_headers(conn) do
    conn
    |> Sentry.PlugContext.default_header_scrubber()
    |> Map.drop(@webhook_headers)
  end

  @doc """
  Redacts bearer tokens in public Direct links, preserving route shape.
  """
  def scrub_url(conn) do
    conn
    |> Sentry.PlugContext.default_url_scrubber()
    |> redact_public_token()
  end

  defp redact_public_token(value) when is_binary(value) do
    Regex.replace(
      ~r{(/direct/(?:invoices|billing-invoices|contract-invoices|contract-letters|worker-letters|pay)/)[^/?#]+},
      value,
      "\\1[Filtered]"
    )
  end

  @doc """
  Removes database credentials and sensitive query parameters from traces.
  """
  def before_send(%Sentry.Transaction{} = transaction) do
    %{
      transaction
      | contexts: scrub_contexts(transaction.contexts),
        spans: scrub_spans(transaction.spans)
    }
  end

  def before_send(event), do: event

  defp scrub_contexts(%{trace: trace} = contexts) when is_map(trace) do
    %{contexts | trace: Map.update(trace, :data, %{}, &scrub_span_data/1)}
  end

  defp scrub_contexts(contexts), do: contexts

  defp scrub_spans(spans) when is_list(spans) do
    Enum.map(spans, fn
      %Sentry.Interfaces.Span{} = span -> %{span | data: scrub_span_data(span.data)}
      other -> other
    end)
  end

  defp scrub_spans(spans), do: spans

  defp scrub_span_data(data) when is_map(data) do
    data
    |> scrub_query_attribute("url.query")
    |> scrub_query_attribute(:"url.query")
    |> scrub_path_attribute("url.path")
    |> scrub_path_attribute(:"url.path")
    |> scrub_path_attribute("url.full")
    |> scrub_path_attribute(:"url.full")
    |> redact_database_url("db.url")
    |> redact_database_url(:"db.url")
  end

  defp scrub_span_data(data), do: data

  defp scrub_query_attribute(data, key) do
    case Map.get(data, key) do
      query when is_binary(query) ->
        Map.put(data, key, Sentry.Scrubber.scrub_query_string(query))

      _ ->
        data
    end
  end

  defp scrub_path_attribute(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) -> Map.put(data, key, redact_public_token(value))
      _ -> data
    end
  end

  defp redact_database_url(data, key) do
    case Map.get(data, key) do
      url when is_binary(url) ->
        if String.contains?(url, "://") and String.contains?(url, "@") do
          Map.put(data, key, "redacted")
        else
          data
        end

      _ ->
        data
    end
  end

  defp path_from_attributes(attributes) when is_map(attributes) do
    Map.get(attributes, "url.path") || Map.get(attributes, :"url.path")
  end

  defp path_from_attributes(attributes) when is_tuple(attributes) do
    attributes
    |> :otel_attributes.map()
    |> path_from_attributes()
  rescue
    _ -> nil
  end

  defp path_from_attributes(_attributes), do: nil
end
