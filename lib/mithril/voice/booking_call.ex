defmodule Mithril.Voice.BookingCall do
  @moduledoc """
  Masked booking calls.

  The app asks Mithril to arm a call, then opens the public Twilio number in
  the phone dialer. Twilio posts the inbound call here. This module decides
  which real phone to ring and returns TwiML that dials it with the Twilio
  number as the caller ID.

  The arm response never includes the other party's phone. A caller's own
  number is stored only so the Twilio `From` value can be matched to the tap.
  """

  alias Mithril.Auth.Phone
  alias Mithril.DbUuid
  alias Mithril.MobileGateway
  alias Mithril.Repo
  alias Mithril.WhatsApp.TwilioSignature

  @intent_seconds 120
  @active_statuses ~w(confirmed scheduled en_route arrived in_progress)

  def arm(user_id, booking_id, contact_role) when is_binary(user_id) do
    with :ok <- ensure_voice_ready(),
         {:ok, booking_id} <- cast_uuid(booking_id),
         {:ok, contact_role} <- cast_role(contact_role),
         {:ok, caller_phone} <- caller_phone(user_id),
         :ok <- authorize(user_id, booking_id, contact_role),
         :ok <- store_intent(user_id, booking_id, contact_role, caller_phone) do
      {:ok, %{dial_number: voice_number()}}
    end
  end

  def arm(_user_id, _booking_id, _contact_role), do: {:error, :invalid_request}

  def handle_webhook(params, signature, request_url) when is_map(params) do
    with :ok <- ensure_webhook_ready(),
         :ok <- verify_signature(params, signature, request_url) do
      case caller_from(params) do
        {:ok, caller_phone} -> connect(caller_phone)
        :error -> {:ok, unavailable_twiml()}
      end
    end
  end

  def handle_webhook(_params, _signature, _request_url), do: {:error, :unauthorized}

  def choose_route(intents, active_routes, caller_phone, now)
      when is_list(intents) and is_list(active_routes) and is_binary(caller_phone) do
    case freshest_intent(intents, caller_phone, now) do
      nil ->
        case active_routes do
          [route] -> {:ok, route}
          [] -> :none
          _routes -> :ambiguous
        end

      intent ->
        {:ok,
         %{
           user_id: intent.caller_user_id,
           booking_id: intent.booking_id,
           contact_role: intent.contact_role
         }}
    end
  end

  defp connect(caller_phone) do
    case store().routes_for_caller(caller_phone, DateTime.utc_now()) do
      {:ok, {:ok, route}} ->
        dial_route(route)

      {:ok, :ambiguous} ->
        {:ok, ambiguous_twiml()}

      {:ok, :none} ->
        {:ok, unavailable_twiml()}

      {:error, _reason} ->
        {:ok, unavailable_twiml()}
    end
  end

  defp dial_route(route) do
    case {voice_number(), destination_for(route)} do
      {caller_id, {:ok, destination}} when is_binary(caller_id) ->
        {:ok, dial_twiml(caller_id, destination)}

      _other ->
        {:ok, unavailable_twiml()}
    end
  end

  defp destination_for(%{user_id: user_id, booking_id: booking_id, contact_role: contact_role}) do
    case contact_lookup().(user_id, booking_id, contact_role) do
      {:ok, phone} when is_binary(phone) ->
        case Phone.normalize(phone) do
          {:ok, e164} -> {:ok, e164}
          :error -> {:error, :unavailable}
        end

      _other ->
        {:error, :unavailable}
    end
  end

  defp store_intent(user_id, booking_id, contact_role, caller_phone) do
    now = DateTime.utc_now()

    intent = %{
      caller_user_id: user_id,
      booking_id: booking_id,
      contact_role: contact_role,
      caller_phone_e164: caller_phone,
      expires_at: DateTime.add(now, @intent_seconds, :second),
      created_at: now
    }

    case store().put_intent(intent) do
      :ok -> :ok
      {:error, _reason} -> {:error, "unable_to_call"}
    end
  end

  defp authorize(user_id, booking_id, contact_role) do
    case contact_lookup().(user_id, booking_id, contact_role) do
      {:ok, phone} when is_binary(phone) ->
        case Phone.normalize(phone) do
          {:ok, _e164} -> :ok
          :error -> {:error, "phone_unavailable"}
        end

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _other ->
        {:error, "phone_unavailable"}
    end
  end

  defp freshest_intent(intents, caller_phone, now) do
    intents
    |> Enum.filter(fn intent ->
      intent.caller_phone_e164 == caller_phone and DateTime.compare(intent.expires_at, now) == :gt
    end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    |> List.first()
  end

  defp caller_phone(user_id) do
    case caller_phone_lookup().(user_id) do
      {:ok, phone} when is_binary(phone) ->
        case Phone.normalize(phone) do
          {:ok, e164} -> {:ok, e164}
          :error -> {:error, :caller_phone_missing}
        end

      _other ->
        {:error, :caller_phone_missing}
    end
  end

  defp caller_from(params) do
    raw = param(params, "From")

    phone =
      cond do
        is_binary(raw) and String.starts_with?(raw, "whatsapp:") ->
          String.replace_prefix(raw, "whatsapp:", "")

        is_binary(raw) ->
          raw

        true ->
          nil
      end

    case Phone.normalize(phone) do
      {:ok, e164} -> {:ok, e164}
      _other -> :error
    end
  end

  defp default_caller_phone(user_id) do
    case Repo.query("SELECT phone FROM public.users WHERE id = $1::uuid LIMIT 1", [
           DbUuid.dump!(user_id)
         ]) do
      {:ok, %{rows: [[phone]]}} when is_binary(phone) -> {:ok, phone}
      _other -> {:error, :caller_phone_missing}
    end
  end

  defp default_contact_lookup(user_id, booking_id, contact_role) do
    args = %{"p_booking_id" => booking_id, "p_contact_role" => contact_role}

    case MobileGateway.call_rpc(user_id, "get_booking_contact_phone", args) do
      {:ok, payload} when is_map(payload) ->
        phone = payload_field(payload, "phone")

        if payload_success?(payload) and is_binary(phone) do
          {:ok, phone}
        else
          {:error, payload_error(payload)}
        end

      _other ->
        {:error, "unable_to_call"}
    end
  end

  defp payload_success?(payload) do
    Map.get(payload, "success") == true or Map.get(payload, :success) == true
  end

  defp payload_field(payload, key) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  defp payload_error(payload) do
    error = payload_field(payload, "error")
    if is_binary(error), do: error, else: "phone_unavailable"
  end

  defp ensure_voice_ready do
    if is_binary(voice_number()) and webhook_token_present?(),
      do: :ok,
      else: {:error, :voice_not_configured}
  end

  defp ensure_webhook_ready do
    if webhook_token_present?(), do: :ok, else: {:error, :not_configured}
  end

  defp webhook_token_present? do
    token = Application.get_env(:mithril, :twilio_auth_token)
    is_binary(token) and token != ""
  end

  defp voice_number do
    [
      Application.get_env(:mithril, :twilio_voice_number),
      Application.get_env(:mithril, :twilio_from_number)
    ]
    |> Enum.find_value(&normalize_configured_number/1)
  end

  defp normalize_configured_number(value) when is_binary(value) do
    case Phone.normalize(value) do
      {:ok, e164} -> e164
      :error -> nil
    end
  end

  defp normalize_configured_number(_value), do: nil

  defp verify_signature(params, signature, request_url) do
    if valid_signature?(params, signature, request_url) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp valid_signature?(params, signature, request_url) do
    if Application.get_env(:mithril, :disable_twilio_signature_validation, false) do
      true
    else
      token = Application.get_env(:mithril, :twilio_auth_token)
      signed_params = string_params(params)

      is_binary(token) and token != "" and
        Enum.any?(signature_urls(request_url), fn url ->
          TwilioSignature.valid?(signed_params, signature, token, url)
        end)
    end
  end

  defp signature_urls(request_url) do
    [
      request_url,
      Application.get_env(:mithril, :twilio_voice_webhook_url),
      Application.get_env(:mithril, :twilio_voice_webhook_url_alias)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp string_params(params) do
    params
    |> Enum.filter(fn {_key, value} ->
      is_binary(value) or is_number(value) or is_boolean(value)
    end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp param(params, key) do
    Map.get(params, key) || Map.get(params, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(params, key)
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_request}

  defp cast_role(nil), do: {:ok, "customer"}

  defp cast_role(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, "customer"}
      "customer" -> {:ok, "customer"}
      "site" -> {:ok, "site"}
      _other -> {:error, "invalid_contact_role"}
    end
  end

  defp cast_role(_value), do: {:error, "invalid_contact_role"}

  defp contact_lookup do
    Application.get_env(:mithril, :voice_contact_lookup, &default_contact_lookup/3)
  end

  defp caller_phone_lookup do
    Application.get_env(:mithril, :voice_caller_phone, &default_caller_phone/1)
  end

  defp store do
    Application.get_env(:mithril, :voice_call_store, __MODULE__.SQL)
  end

  defp dial_twiml(caller_id, destination) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Dial callerId="#{caller_id}" timeout="25">
        <Number>#{destination}</Number>
      </Dial>
    </Response>
    """
  end

  defp unavailable_twiml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Say>Open Instaclean and tap Call on the job you want.</Say>
    </Response>
    """
  end

  defp ambiguous_twiml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Response>
      <Say>You have more than one active job. Open Instaclean and tap Call on the job you want.</Say>
    </Response>
    """
  end

  defmodule Memory do
    @moduledoc false

    def reset do
      ensure()
      Agent.update(__MODULE__, fn _state -> empty() end)
    end

    def intent_count do
      ensure()
      Agent.get(__MODULE__, fn state -> length(state.intents) end)
    end

    def put_intent(intent) do
      ensure()
      Agent.update(__MODULE__, fn state ->
        remaining = Enum.reject(state.intents, &(&1.caller_phone_e164 == intent.caller_phone_e164))
        %{state | intents: [intent | remaining]}
      end)
      :ok
    end

    def put_active_routes(caller_phone, routes)
        when is_binary(caller_phone) and is_list(routes) do
      ensure()

      Agent.update(__MODULE__, fn state ->
        %{state | active_routes: Map.put(state.active_routes, caller_phone, routes)}
      end)
    end

    def routes_for_caller(caller_phone, now) do
      ensure()

      Agent.get(__MODULE__, fn state ->
        active_routes = Map.get(state.active_routes, caller_phone, [])

        {:ok,
         Mithril.Voice.BookingCall.choose_route(state.intents, active_routes, caller_phone, now)}
      end)
    end

    defp ensure do
      case Process.whereis(__MODULE__) do
        nil ->
          case Agent.start_link(fn -> empty() end, name: __MODULE__) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end

        pid ->
          pid
      end
    end

    defp empty, do: %{intents: [], active_routes: %{}}
  end

  defmodule SQL do
    @moduledoc false

    alias Mithril.Auth.Phone
    alias Mithril.DbUuid
    alias Mithril.Repo

    def put_intent(intent) do
      with :ok <- delete_expired(),
           :ok <- insert_intent(intent) do
        :ok
      end
    end

    def routes_for_caller(caller_phone, now) do
      with {:ok, intents} <- intents_for_phone(caller_phone),
           {:ok, active_routes} <- active_routes_for_phone(caller_phone) do
        {:ok, Mithril.Voice.BookingCall.choose_route(intents, active_routes, caller_phone, now)}
      end
    end

    defp insert_intent(intent) do
      sql = """
      INSERT INTO public.voice_call_intents (
        caller_user_id, booking_id, contact_role, caller_phone_e164, expires_at, created_at
      ) VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6)
      ON CONFLICT (caller_phone_e164) DO UPDATE SET
        caller_user_id = EXCLUDED.caller_user_id,
        booking_id = EXCLUDED.booking_id,
        contact_role = EXCLUDED.contact_role,
        expires_at = EXCLUDED.expires_at,
        created_at = EXCLUDED.created_at
      """

      params = [
        DbUuid.dump!(intent.caller_user_id),
        DbUuid.dump!(intent.booking_id),
        intent.contact_role,
        intent.caller_phone_e164,
        intent.expires_at,
        intent.created_at
      ]

      case Repo.query(sql, params) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp delete_expired do
      sql = "DELETE FROM public.voice_call_intents WHERE expires_at < now() - interval '1 day'"

      case Repo.query(sql, []) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp intents_for_phone(caller_phone) do
      sql = """
      SELECT caller_user_id::text, booking_id::text, contact_role,
             caller_phone_e164, expires_at, created_at
      FROM public.voice_call_intents
      WHERE caller_phone_e164 = $1 AND expires_at > now()
      ORDER BY created_at DESC
      LIMIT 5
      """

      case Repo.query(sql, [caller_phone]) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &intent_from_row/1)}
        {:error, reason} -> {:error, reason}
      end
    end

    defp intent_from_row([user_id, booking_id, contact_role, phone, expires_at, created_at]) do
      %{
        caller_user_id: user_id,
        booking_id: booking_id,
        contact_role: contact_role,
        caller_phone_e164: phone,
        expires_at: expires_at,
        created_at: created_at
      }
    end

    defp active_routes_for_phone(caller_phone) do
      case users_for_phone(caller_phone) do
        {:ok, []} ->
          {:ok, []}

        {:ok, [user_id]} ->
          bookings_for_user(user_id)

        {:ok, _user_ids} ->
          {:ok, ambiguous_routes()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp users_for_phone(caller_phone) do
      sql = """
      SELECT id::text, phone
      FROM public.users
      WHERE phone = ANY($1::text[])
      LIMIT 5
      """

      case Repo.query(sql, [phone_lookup_values(caller_phone)]) do
        {:ok, %{rows: rows}} ->
          matches =
            Enum.flat_map(rows, fn [user_id, stored_phone] ->
              case Phone.normalize(stored_phone) do
                {:ok, ^caller_phone} -> [user_id]
                _other -> []
              end
            end)

          {:ok, Enum.uniq(matches)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp bookings_for_user(user_id) do
      sql = """
      SELECT id::text
      FROM public.bookings
      WHERE (customer_id = $1::uuid OR cleaner_id = $1::uuid)
        AND status::text = ANY($2::text[])
        AND cleaner_accepted_at IS NOT NULL
        AND lower(coalesce(assignment_phase, '')) = 'accepted'
      ORDER BY scheduled_at_utc DESC NULLS LAST
      LIMIT 2
      """

      case Repo.query(sql, [DbUuid.dump!(user_id), Mithril.Voice.BookingCall.active_statuses()]) do
        {:ok, %{rows: rows}} ->
          {:ok,
           Enum.map(rows, fn [booking_id] ->
             %{user_id: user_id, booking_id: booking_id, contact_role: "customer"}
           end)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp ambiguous_routes do
      [
        %{user_id: "ambiguous", booking_id: "ambiguous-a", contact_role: "customer"},
        %{user_id: "ambiguous", booking_id: "ambiguous-b", contact_role: "customer"}
      ]
    end

    defp phone_lookup_values(e164) do
      digits = String.trim_leading(e164, "+")

      local =
        case digits do
          "233" <> rest -> ["0" <> rest]
          _other -> []
        end

      Enum.uniq([e164, digits | local])
    end
  end

  def active_statuses, do: @active_statuses
end
