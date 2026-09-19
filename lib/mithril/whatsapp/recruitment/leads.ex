defmodule Mithril.WhatsApp.Recruitment.Leads do
  @moduledoc false

  alias Mithril.WhatsApp.Recruitment.Payload

  def get_or_create(phone) do
    store().get_or_create(phone)
  end

  def persist(phone, patch) do
    store().persist(phone, patch)
  end

  def get(id) do
    store().get(id)
  end

  def fetch_service_catalog do
    store().fetch_service_catalog()
  end

  def issue_continuation_code(phone) do
    canonical = continuation_code()
    expires = DateTime.add(DateTime.utc_now(), 7 * 24 * 60 * 60, :second)

    with :ok <-
           persist(phone, %{
             web_continuation_code: canonical,
             web_continuation_code_expires_at: expires
           }) do
      {:ok, %{canonical: canonical, display: format_code(canonical)}}
    end
  end

  defp store do
    Application.get_env(:mithril, :whatsapp_recruitment_store, __MODULE__.SQL)
  end

  defp continuation_code do
    alphabet = ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    1..8
    |> Enum.map(fn _ -> Enum.at(alphabet, :rand.uniform(length(alphabet)) - 1) end)
    |> List.to_string()
  end

  defp format_code(canonical) when byte_size(canonical) == 8 do
    String.slice(canonical, 0, 4) <> "-" <> String.slice(canonical, 4, 4)
  end

  defp format_code(canonical), do: canonical

  defmodule SQL do
    @moduledoc false

    alias Mithril.Repo
    alias Mithril.WhatsApp.Recruitment.Payload

    def get_or_create(phone) do
      case fetch_by_phone(phone) do
        {:ok, lead} ->
          {:ok, lead}

        {:error, :not_found} ->
          insert(phone)

        other ->
          other
      end
    end

    def get(id) do
      with {:ok, uuid} <- Ecto.UUID.dump(id),
           {:ok, %{rows: [row], columns: columns}} <-
             Repo.query("SELECT * FROM public.cleaner_leads WHERE id = $1 LIMIT 1", [uuid]) do
        {:ok, row_to_lead(columns, row)}
      else
        {:ok, %{rows: []}} -> {:error, :not_found}
        :error -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end

    def persist(phone, patch) do
      {assignments, values} = update_assignments(patch)

      sql = """
      UPDATE public.cleaner_leads
      SET #{assignments}, updated_at = now()
      WHERE phone = $1
      """

      case Repo.query(sql, [phone | values]) do
        {:ok, _} -> :ok
        {:error, error} -> {:error, error}
      end
    end

    def fetch_service_catalog do
      sql = """
      SELECT st.id, st.name, COALESCE(sc.name, 'Services')
      FROM public.service_types st
      LEFT JOIN public.service_categories sc ON sc.id = st.category_id
      WHERE st.active = true
      ORDER BY st.name
      """

      case Repo.query(sql, []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [id, name, category] ->
            %{id: id, name: name, category: category}
          end)

        {:error, _} ->
          []
      end
    end

    defp fetch_by_phone(phone) do
      case Repo.query("SELECT * FROM public.cleaner_leads WHERE phone = $1 LIMIT 1", [phone]) do
        {:ok, %{rows: [row], columns: columns}} -> {:ok, row_to_lead(columns, row)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, error} -> {:error, error}
      end
    end

    defp insert(phone) do
      payload = Jason.encode!(Payload.default())

      sql = """
      INSERT INTO public.cleaner_leads (
        phone, source, status, current_step, step, step_history, payload, updated_at
      ) VALUES (
        $1, 'whatsapp', 'new', 'awaiting_apply', 'awaiting_apply', '[]'::jsonb, $2::jsonb, now()
      )
      RETURNING *
      """

      case Repo.query(sql, [phone, payload]) do
        {:ok, %{rows: [row], columns: columns}} ->
          {:ok, row_to_lead(columns, row)}

        {:error, %{postgres: %{code: :unique_violation}}} ->
          fetch_by_phone(phone)

        {:error, error} ->
          {:error, error}
      end
    end

    defp update_assignments(patch) do
      allowed = [
        :current_step,
        :step,
        :step_history,
        :payload,
        :status,
        :name,
        :email,
        :area,
        :experience,
        :availability,
        :id_media_url,
        :ghana_card_front_path,
        :ghana_card_back_path,
        :submitted_at,
        :web_continuation_code,
        :web_continuation_code_expires_at
      ]

      {sets, values, _} =
        Enum.reduce(allowed, {[], [], 2}, fn key, {sets, values, index} ->
          if Map.has_key?(patch, key) do
            {["#{key} = #{placeholder(key, index)}" | sets], [dump(key, Map.get(patch, key)) | values],
             index + 1}
          else
            {sets, values, index}
          end
        end)

      {Enum.join(Enum.reverse(sets), ", "), Enum.reverse(values)}
    end

    defp placeholder(:payload, index), do: "$#{index}::jsonb"
    defp placeholder(:step_history, index), do: "$#{index}::jsonb"
    defp placeholder(:web_continuation_code_expires_at, index), do: "$#{index}::timestamptz"
    defp placeholder(:submitted_at, index), do: "$#{index}::timestamptz"
    defp placeholder(_key, index), do: "$#{index}"

    defp dump(:payload, value), do: Jason.encode!(value)
    defp dump(:step_history, value), do: Jason.encode!(List.wrap(value))
    defp dump(_key, %DateTime{} = value), do: value
    defp dump(_key, value), do: value

    defp row_to_lead(columns, row) do
      data =
        columns
        |> Enum.zip(row)
        |> Map.new(fn {column, value} -> {column, value} end)

      %{
        id: uuid(data["id"]),
        phone: to_string(data["phone"]),
        source: data["source"],
        status: data["status"] || "new",
        current_step: data["current_step"] || "awaiting_apply",
        step: data["step"],
        step_history: history(data["step_history"]),
        payload: Payload.merge(decode_json(data["payload"])),
        name: data["name"],
        email: data["email"],
        area: data["area"],
        experience: data["experience"],
        availability: data["availability"],
        id_media_url: data["id_media_url"],
        ghana_card_front_path: data["ghana_card_front_path"],
        ghana_card_back_path: data["ghana_card_back_path"],
        linked_user_id: uuid(data["linked_user_id"]),
        submitted_at: data["submitted_at"]
      }
    end

    defp history(value) when is_list(value), do: Enum.map(value, &to_string/1)
    defp history(value) when is_binary(value) do
      case Jason.decode(value) do
        {:ok, list} when is_list(list) -> Enum.map(list, &to_string/1)
        _ -> []
      end
    end

    defp history(_), do: []

    defp decode_json(value) when is_map(value), do: value
    defp decode_json(value) when is_binary(value) do
      case Jason.decode(value) do
        {:ok, map} -> map
        _ -> %{}
      end
    end

    defp decode_json(_), do: %{}

    defp uuid(nil), do: nil
    defp uuid(value) when is_binary(value) do
      case Ecto.UUID.load(value) do
        {:ok, id} -> id
        :error -> if byte_size(value) == 36, do: value, else: nil
      end
    end

    defp uuid(_), do: nil
  end

  defmodule Memory do
    @moduledoc false

    alias Mithril.WhatsApp.Recruitment.Payload

    def start_link do
      Agent.start_link(fn -> %{by_phone: %{}, by_id: %{}} end, name: __MODULE__)
    end

    def reset do
      if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _ -> %{by_phone: %{}, by_id: %{}} end)
    end

    def get_or_create(phone) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state.by_phone, phone) do
          nil ->
            lead = new_lead(phone)
            state = put_lead(state, lead)
            {{:ok, lead}, state}

          lead ->
            {{:ok, lead}, state}
        end
      end)
    end

    def get(id) do
      case Agent.get(__MODULE__, &Map.get(&1.by_id, id)) do
        nil -> {:error, :not_found}
        lead -> {:ok, lead}
      end
    end

    def persist(phone, patch) do
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state.by_phone, phone) do
          nil ->
            {{:error, :not_found}, state}

          lead ->
            updated = Map.merge(lead, atomize_patch(patch))
            {{:ok, :ok}, put_lead(state, updated)}
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        other -> other
      end
    end

    def fetch_service_catalog, do: []

    defp new_lead(phone) do
      id = Ecto.UUID.generate()

      %{
        id: id,
        phone: phone,
        source: "whatsapp",
        status: "new",
        current_step: "awaiting_apply",
        step: "awaiting_apply",
        step_history: [],
        payload: Payload.default(),
        name: nil,
        email: nil,
        area: nil,
        experience: nil,
        availability: nil,
        id_media_url: nil,
        ghana_card_front_path: nil,
        ghana_card_back_path: nil,
        linked_user_id: nil,
        submitted_at: nil
      }
    end

    defp put_lead(state, lead) do
      %{
        by_phone: Map.put(state.by_phone, lead.phone, lead),
        by_id: Map.put(state.by_id, lead.id, lead)
      }
    end

    defp atomize_patch(patch) do
      Map.new(patch, fn
        {key, value} when is_atom(key) -> {key, value}
        {key, value} -> {String.to_existing_atom(to_string(key)), value}
      end)
    end
  end
end
