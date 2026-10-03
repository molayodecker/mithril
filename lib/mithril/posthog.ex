defmodule Mithril.Posthog do
  @moduledoc false

  @default_host "https://us.i.posthog.com"
  @timeout_ms 3_000

  @booking_uber_transportation_flag "booking_uber_transportation_v1"
  @uber_release_gate_distinct_id "instaclean-uber-transportation-release-gate"
  @booking_stripe_checkout_flag "booking_stripe_checkout_v1"
  # Non-user id so the release check does not send a customer identity.
  # Staging PostHog project is 514497. Production is 514495.
  # POSTHOG_PROJECT_API_KEY selects the project.
  @stripe_release_gate_distinct_id "instaclean-stripe-checkout-release-gate"

  def booking_uber_transportation_flag, do: @booking_uber_transportation_flag
  def uber_release_gate_distinct_id, do: @uber_release_gate_distinct_id
  def booking_stripe_checkout_flag, do: @booking_stripe_checkout_flag
  def stripe_release_gate_distinct_id, do: @stripe_release_gate_distinct_id

  @spec fetch_boolean_flag(String.t(), String.t(), keyword()) :: boolean()
  def fetch_boolean_flag(flag_key, distinct_id, opts \\ [])
      when is_binary(flag_key) and is_binary(distinct_id) and is_list(opts) do
    api_key = api_key()

    if api_key == "" do
      false
    else
      host = flags_host()

      body =
        %{
          api_key: api_key,
          distinct_id: distinct_id,
          groups: %{},
          person_properties: %{},
          group_properties: %{},
          flag_keys_to_evaluate: [flag_key]
        }
        |> maybe_put_evaluation_runtime(Keyword.get(opts, :evaluation_runtime))
        |> Jason.encode!()

      task =
        Task.async(fn ->
          Req.post("#{host}/flags/?v=2",
            headers: [{"content-type", "application/json"}],
            body: body,
            receive_timeout: @timeout_ms
          )
        end)

      try do
        case Task.await(task, @timeout_ms + 500) do
          {:ok, %{status: status, body: payload}} when status in 200..299 ->
            read_boolean_flag(payload, flag_key)

          _ ->
            false
        end
      catch
        :exit, _ -> false
      end
    end
  end

  @spec read_boolean_flag(term(), String.t()) :: boolean()
  def read_boolean_flag(payload, flag_key) when is_binary(flag_key) do
    root = if is_map(payload), do: payload, else: %{}

    flags = Map.get(root, "flags") || Map.get(root, :flags) || %{}

    cond do
      is_map(flags) and Map.has_key?(flags, flag_key) ->
        raw = Map.get(flags, flag_key)

        cond do
          is_boolean(raw) -> raw
          is_map(raw) and is_boolean(Map.get(raw, "enabled")) -> Map.get(raw, "enabled")
          is_map(raw) and is_boolean(Map.get(raw, :enabled)) -> Map.get(raw, :enabled)
          true -> false
        end

      true ->
        legacy = Map.get(root, "featureFlags") || Map.get(root, :featureFlags) || %{}

        if is_map(legacy) and is_boolean(Map.get(legacy, flag_key)) do
          Map.get(legacy, flag_key)
        else
          false
        end
    end
  end

  defp maybe_put_evaluation_runtime(payload, runtime)
       when is_binary(runtime) and runtime != "" do
    Map.put(payload, :evaluation_runtime, runtime)
  end

  defp maybe_put_evaluation_runtime(payload, _runtime), do: payload

  defp api_key do
    Application.get_env(:mithril, :posthog_project_api_key, "")
    |> to_string()
    |> String.trim()
  end

  defp flags_host do
    Application.get_env(:mithril, :posthog_flags_host, @default_host)
    |> to_string()
    |> String.trim_trailing("/")
  end
end
