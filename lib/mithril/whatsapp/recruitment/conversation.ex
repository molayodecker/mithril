defmodule Mithril.WhatsApp.Recruitment.Conversation do
  @moduledoc false

  require Logger

  alias Mithril.WhatsApp.Recruitment.Leads
  alias Mithril.WhatsApp.Recruitment.Outbound
  alias Mithril.WhatsApp.Recruitment.Parse
  alias Mithril.WhatsApp.Recruitment.Payload
  alias Mithril.WhatsApp.Recruitment.Rosie

  @q_prior "Have you worked as a cleaner before?"
  @q_ref2 "Add a second reference?"
  @q_ref3 "Add a third reference?"
  @q_office "Have you cleaned offices before?"
  @q_cook "Completed a cooking course?"
  @q_license "Do you have a valid driver license?"
  @q_terms "Agree to Terms, Privacy, and 15% platform fee on completed bookings?"
  @q_background "Consent to background check?"
  @q_equipment "Own cleaning equipment?"
  @address_prompt "What is your home address?\n\nYou can:\n1. Type your full address or nearest landmark\n2. Share your current WhatsApp location pin\n\nExample: East Legon, near American House"
  @relationships ["Client", "Employer", "Supervisor", "Family Friend", "Colleague"]
  @admin_default ["+233559100642"]

  def handle(params) do
    message = params |> Parse.effective_message() |> String.trim()
    cmd = Parse.normalize_command(message)
    from = Parse.strip_whatsapp_prefix(Parse.string_param(params, "From"))
    to = Parse.string_param(params, "To")
    business = Parse.strip_whatsapp_prefix(to)
    ctx = %{to: Parse.string_param(params, "From"), from: to}
    {lat, lng} = coords(params)

    cond do
      business != "" and admin_line?(business) ->
        reply(
          {:text,
           "This WhatsApp line is for customer support. Visit tryinstaclean.com/join-as-cleaner to apply as a cleaner."},
          ctx
        )

      from == "" ->
        reply({:text, "We could not identify your phone number. Please try again."}, ctx)

      true ->
        run(from, message, cmd, ctx, lat, lng)
    end
  rescue
    error ->
      Logger.error("whatsapp recruitment fatal #{Exception.message(error)}")
      reply({:text, "Something went wrong. Please try again."}, %{to: "", from: ""})
  end

  defp run(from, message, cmd, ctx, lat, lng) do
    app_url = app_url()
    join_url = "#{app_url}/join-as-cleaner"

    with {:ok, lead} <- Leads.get_or_create(from) do
      lead = from |> reset_unknown_step(lead) |> then(&skip_retired_steps(from, &1))

      cond do
        cmd == "CODE" ->
          code_reply(from, join_url, ctx)

        cmd == "SIGNUP" ->
          signup_reply(from, lead, ctx)

        cmd == "STATUS" ->
          reply({:plain, status_message(lead, join_url)}, ctx)

        cmd == "RESTART" ->
          restart(from, ctx)

        cmd == "BACK" ->
          back(from, lead, ctx)

        cmd == "CONTINUE" ->
          prompt(lead, ctx)

        faq = Rosie.maybe_reply(message, cmd, app_url, lead.current_step) ->
          reply({:plain, faq}, ctx)

        lead.current_step == "completed" ->
          completed(lead, cmd, join_url, ctx)

        lead.current_step == "awaiting_apply" ->
          awaiting_apply(from, lead, cmd, message, ctx)

        cmd == "APPLY" ->
          reply(
            {:text, "You already started. Reply STATUS for progress or RESTART to begin again."},
            ctx
          )

        true ->
          step(from, lead, message, cmd, ctx, lat, lng)
      end
    else
      {:error, error} ->
        Logger.error("whatsapp recruitment lead error #{inspect(error)}")
        reply({:text, "Something went wrong. Please try again or say HELP."}, ctx)
    end
  end

  defp awaiting_apply(from, lead, cmd, message, ctx) do
    if cmd == "APPLY" or String.upcase(String.trim(message)) == "APPLY" do
      p = lead.payload

      p =
        put_in(
          p,
          ["personalInfo", "phone"],
          Parse.normalize_ghana_phone(from) || String.trim(from)
        )

      adv = Payload.advance(lead, "personal_email")
      save(from, Map.merge(adv, %{payload: p}))
      reply({:text, "What is your email address?\n\nReply SKIP to add it later."}, ctx)
    else
      reply(welcome(), ctx)
    end
  end

  defp completed(lead, cmd, join_url, ctx) do
    sign_in = "#{app_url()}/sign-in"

    cond do
      cmd == "APPLY" ->
        reply(
          {:plain,
           "Your draft is already saved ✅\n\nReply SIGNUP to continue with phone sign-in, or open:\n#{join_url}"},
          ctx
        )

      cmd == "SUBMIT" ->
        Mithril.WhatsApp.Recruitment.Mirror.maybe_sync(lead.id)
        _ = Outbound.send_plain_text(ctx.to, ctx.from, "Processing your request…")
        reply({:plain, submitted_message(sign_in)}, ctx)

      true ->
        reply(
          {:plain,
           "Your application draft is saved ✅\n\nReply SIGNUP to sign in with your phone and continue verification.\nReply WEB if you prefer to open the website with a continue code.\n\n#{join_url}\n\nReply RESTART to start over."},
          ctx
        )
    end
  end

  defp restart(from, ctx) do
    save(from, %{
      payload: Payload.default(),
      step_history: [],
      current_step: "awaiting_apply",
      step: "awaiting_apply",
      status: "new",
      name: nil,
      email: nil,
      area: nil,
      experience: nil,
      availability: nil,
      id_media_url: nil,
      ghana_card_front_path: nil,
      ghana_card_back_path: nil,
      submitted_at: nil
    })

    reply(welcome("Started fresh."), ctx)
  end

  defp back(from, lead, ctx) do
    case Payload.go_back(lead) do
      nil ->
        reply({:text, "You are at the first step. Reply RESTART to reset fully."}, ctx)

      patch ->
        save(from, patch)
        prompt(Map.merge(lead, patch), ctx)
    end
  end

  defp step(from, lead, message, cmd, ctx, lat, lng) do
    p = lead.payload

    case lead.current_step do
      "personal_email" ->
        personal_email(from, lead, p, message, cmd, ctx)

      "personal_first_name" ->
        required_text(
          from,
          lead,
          p,
          message,
          ctx,
          ["personalInfo", "firstName"],
          "personal_last_name",
          "What is your last name?",
          "Please enter your first name.\n\nWhat is your first name?",
          name?: true
        )

      "personal_last_name" ->
        required_text(
          from,
          lead,
          p,
          message,
          ctx,
          ["personalInfo", "lastName"],
          "personal_address",
          @address_prompt,
          "Please enter your last name.\n\nWhat is your last name?",
          name?: true
        )

      "personal_address" ->
        personal_address(from, lead, p, message, ctx, lat, lng)

      "personal_city_area" ->
        personal_city_area(from, lead, p, message, ctx)

      "personal_city_other" ->
        required_text(
          from,
          lead,
          p,
          message,
          ctx,
          ["personalInfo", "city"],
          "personal_bio",
          "Tell customers about yourself (max 500 chars).\n\nReply SKIP to add later.",
          "Please type which area you are in.\n\nWhich area? (free text)",
          area?: true
        )

      "personal_bio" ->
        personal_bio(from, lead, p, message, cmd, ctx)

      "experience_has_cleaned" ->
        experience_has_cleaned(from, lead, p, message, ctx)

      "years_of_experience" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          4,
          ["<1 year", "1–2 years", "3–5 years", ">5 years"],
          ["experience", "yearsOfExperience"],
          "previous_employers",
          "Where have you worked before?\n\nReply SKIP if not applicable.",
          years_prompt()
        )

      "previous_employers" ->
        skippable(
          from,
          lead,
          p,
          message,
          cmd,
          ctx,
          ["experience", "previousEmployers"],
          "ref1_name",
          "Reference 1: what is their name?"
        )

      "ref1_name" ->
        required_text(
          from,
          lead,
          p,
          message,
          ctx,
          ["references", "client1Name"],
          "ref1_contact",
          "Reference 1 phone?\nExample: +233 55 123 4567",
          "A name is required for this reference.\n\nReference 1: what is their name?"
        )

      "ref1_contact" ->
        phone_field(
          from,
          lead,
          p,
          message,
          ctx,
          ["references", "client1Contact"],
          "ref1_relationship",
          relationship_prompt(1),
          "That does not look like a valid phone number.\n\nReference 1 phone?\nExample: +233 55 123 4567"
        )

      "ref1_relationship" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          5,
          @relationships,
          ["references", "client1Relationship"],
          "ask_ref2",
          yes_no(@q_ref2),
          relationship_prompt(1),
          quick?: true
        )

      "ask_ref2" ->
        yes_no_branch(
          from,
          lead,
          p,
          message,
          ctx,
          "ref2_name",
          "ask_ref3",
          "Reference 2: name?",
          yes_no(@q_ref3),
          @q_ref2
        )

      "ref2_name" ->
        required_text(
          from,
          lead,
          p,
          message,
          ctx,
          ["references", "client2Name"],
          "ref2_contact",
          "Reference 2 phone?",
          "Please enter their name.\n\nReference 2: name?"
        )

      "ref2_contact" ->
        phone_field(
          from,
          lead,
          p,
          message,
          ctx,
          ["references", "client2Contact"],
          "ref2_relationship",
          relationship_prompt(nil),
          "That does not look like a valid phone number.\n\nReference 2 phone?"
        )

      "ref2_relationship" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          5,
          @relationships,
          ["references", "client2Relationship"],
          "ask_ref3",
          yes_no(@q_ref3),
          relationship_prompt(nil),
          quick?: true
        )

      "ask_ref3" ->
        yes_no_branch(
          from,
          lead,
          p,
          message,
          ctx,
          "ref3_name",
          "client_description",
          "Reference 3: name?",
          {:menu, client_desc_prompt()},
          @q_ref3
        )

      "ref3_name" ->
        required_text(
          from,
          lead,
          p,
          message,
          ctx,
          ["references", "client3Name"],
          "ref3_contact",
          "Reference 3 phone?",
          "Please enter their name.\n\nReference 3: name?"
        )

      "ref3_contact" ->
        phone_field(
          from,
          lead,
          p,
          message,
          ctx,
          ["references", "client3Contact"],
          "ref3_relationship",
          relationship_prompt(nil),
          "That does not look like a valid phone number.\n\nReference 3 phone?"
        )

      "ref3_relationship" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          5,
          @relationships,
          ["references", "client3Relationship"],
          "client_description",
          {:menu, client_desc_prompt()},
          relationship_prompt(nil)
        )

      "client_description" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          5,
          client_desc_opts(),
          ["experience", "clientDescription"],
          "specializations",
          {:multi, spec_prompt(), 5},
          client_desc_prompt()
        )

      "specializations" ->
        multi(
          from,
          lead,
          p,
          message,
          ctx,
          5,
          spec_opts(),
          ["services", "specializations"],
          "certifications",
          {:text, "Certifications or training?\n\nReply SKIP if none."},
          spec_prompt()
        )

      "certifications" ->
        certifications(from, lead, p, message, cmd, ctx)

      "services_offered" ->
        services_offered(from, lead, p, message, cmd, ctx)

      "equipment" ->
        equipment(from, lead, p, message, ctx)

      "availability_days" ->
        availability_days(from, lead, p, message, cmd, ctx)

      "hours_per_week" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          4,
          ["<10 hours", "10–20 hours", "20–40 hours", "40+ hours / full-time"],
          ["availability", "hoursPerWeek"],
          "preferred_shifts",
          {:multi, shifts_prompt(), 4},
          hours_prompt()
        )

      "preferred_shifts" ->
        preferred_shifts(from, lead, p, message, cmd, ctx)

      "start_date" ->
        start_date(from, lead, p, message, ctx)

      "work_areas" ->
        work_areas(from, lead, p, message, ctx)

      "office_cleaning_skill" ->
        yes_no_set(
          from,
          lead,
          p,
          message,
          ctx,
          ["skills", "cleanedOffices"],
          "ironing_confidence",
          {:menu, confidence_prompt("Ironing")},
          @q_office
        )

      "ironing_confidence" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          3,
          confidence_opts(),
          ["skills", "ironingConfidence"],
          "laundry_confidence",
          {:menu, confidence_prompt("Laundry")},
          confidence_prompt("Ironing")
        )

      "laundry_confidence" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          3,
          confidence_opts(),
          ["skills", "laundryConfidence"],
          "pets",
          {:menu, pets_prompt()},
          confidence_prompt("Laundry")
        )

      "pets" ->
        menu(
          from,
          lead,
          p,
          message,
          ctx,
          4,
          pets_opts(),
          ["skills", "petComfort"],
          "cooking_course",
          yes_no(@q_cook),
          pets_prompt(),
          quick?: true
        )

      "cooking_course" ->
        yes_no_set(
          from,
          lead,
          p,
          message,
          ctx,
          ["skills", "cookingCourse"],
          "drivers_license",
          yes_no(@q_license),
          @q_cook
        )

      "drivers_license" ->
        yes_no_set(
          from,
          lead,
          p,
          message,
          ctx,
          ["skills", "driversLicense"],
          "local_languages",
          {:multi, local_lang_prompt(), 5},
          @q_license
        )

      "local_languages" ->
        languages(
          from,
          lead,
          p,
          message,
          ctx,
          5,
          ["Twi", "Ga", "Ewe", "Hausa", "None"],
          5,
          ["skills", "localLanguages"],
          "international_languages",
          {:multi, intl_lang_prompt(), 4},
          local_lang_prompt()
        )

      "international_languages" ->
        international_languages(from, lead, p, message, ctx)

      "ghana_card_front" ->
        skip_ghana_to_terms(from, lead, ctx)

      "ghana_card_back" ->
        skip_ghana_to_terms(from, lead, ctx)

      "terms_agreement" ->
        terms(from, lead, p, message, ctx)

      "background_check" ->
        background(from, lead, p, message, ctx)

      "whatsapp_background_verify" ->
        background_verify(from, lead, p, message, cmd, ctx)

      "review_submit" ->
        review_submit(from, lead, p, cmd, ctx)

      _ ->
        Logger.error("unhandled recruitment step #{lead.current_step}")
        reply({:text, "Something went wrong with your session. Reply RESTART or HELP."}, ctx)
    end
  end

  defp personal_email(from, lead, p, message, cmd, ctx) do
    if cmd == "SKIP" do
      p = put_in(p, ["personalInfo", "email"], nil)
      advance_save(from, lead, p, "personal_first_name", %{email: nil})
      reply({:text, "What is your first name?"}, ctx)
    else
      if Parse.validate_email(message) do
        email = Parse.normalize_email(message)
        p = put_in(p, ["personalInfo", "email"], email)
        advance_save(from, lead, p, "personal_first_name", %{email: email})
        reply({:text, "What is your first name?"}, ctx)
      else
        reply(
          {:text,
           "That does not look like a valid email.\n\nWhat is your email address? Reply SKIP to add it later."},
          ctx
        )
      end
    end
  end

  defp personal_address(from, lead, p, message, ctx, lat, lng) do
    if String.trim(message) == "" and is_nil(lat) do
      reply(
        {:text,
         "Please type your address or share your WhatsApp location pin.\n\n#{@address_prompt}"},
        ctx
      )
    else
      p =
        p
        |> maybe_put_address(message, lat, lng)
        |> maybe_put_coords(lat, lng)

      advance_save(from, lead, p, "personal_city_area", %{
        area: get_in(p, ["personalInfo", "address"])
      })

      reply({:menu, city_prompt()}, ctx)
    end
  end

  defp personal_city_area(from, lead, p, message, ctx) do
    areas = Payload.areas()

    case Parse.parse_menu_choice(message, length(areas)) do
      nil ->
        reply({:menu, city_prompt()}, ctx)

      n ->
        area = Enum.at(areas, n - 1)

        if area == "Other" do
          advance_save(from, lead, p, "personal_city_other")
          reply({:text, "Which area? (free text)"}, ctx)
        else
          p = put_in(p, ["personalInfo", "city"], area)
          advance_save(from, lead, p, "personal_bio", %{area: area})

          reply(
            {:text, "Tell customers about yourself (max 500 chars).\n\nReply SKIP to add later."},
            ctx
          )
        end
    end
  end

  defp personal_bio(from, lead, p, message, cmd, ctx) do
    cond do
      cmd == "SKIP" ->
        p = put_in(p, ["personalInfo", "bio"], "")
        advance_save(from, lead, p, "experience_has_cleaned")
        reply(yes_no(@q_prior), ctx)

      String.length(message) > 500 ->
        reply(
          {:text,
           "Too long. Max 500 characters.\n\nTell customers about yourself, or reply SKIP to add it later."},
          ctx
        )

      true ->
        p = put_in(p, ["personalInfo", "bio"], String.trim(message))
        advance_save(from, lead, p, "experience_has_cleaned")
        reply(yes_no(@q_prior), ctx)
    end
  end

  defp experience_has_cleaned(from, lead, p, message, ctx) do
    case Parse.yes_no_choice(message) do
      nil ->
        reply(
          yes_no(
            @q_prior,
            "Use the Yes or No buttons, or type Yes / No (or reply 1 / 2).\n\n#{@q_prior}"
          ),
          ctx
        )

      2 ->
        p =
          p
          |> put_in(["experience", "hasExperience"], false)
          |> put_in(["experience", "yearsOfExperience"], "")
          |> put_in(["experience", "previousEmployers"], "")

        advance_save(from, lead, p, "ref1_name")
        reply({:text, "Reference 1: what is their name?"}, ctx)

      _ ->
        p = put_in(p, ["experience", "hasExperience"], true)
        advance_save(from, lead, p, "years_of_experience")
        reply({:menu, years_prompt()}, ctx)
    end
  end

  defp certifications(from, lead, p, message, cmd, ctx) do
    p =
      put_in(
        p,
        ["services", "certifications"],
        if(cmd == "SKIP", do: "", else: String.trim(message))
      )

    catalog = Leads.fetch_service_catalog()
    flow = Map.merge(p["_flow"] || %{}, %{"serviceCatalog" => catalog, "servicesPage" => 0})
    p = Map.put(p, "_flow", flow)

    if catalog == [] do
      p = put_in(p, ["services", "servicesOffered"], [])
      advance_save(from, lead, p, "equipment")
      reply(equipment_qr(), ctx)
    else
      advance_save(from, lead, p, "services_offered")
      reply({:multi, services_prompt(catalog, 0), length(catalog)}, ctx)
    end
  end

  defp services_offered(from, lead, p, message, cmd, ctx) do
    catalog = get_in(p, ["_flow", "serviceCatalog"]) || Leads.fetch_service_catalog()
    p = put_in(p, ["_flow", "serviceCatalog"], catalog)
    page = get_in(p, ["_flow", "servicesPage"]) || 0

    cond do
      cmd == "MORE" ->
        max_page = max(0, ceil(length(catalog) / 8) - 1)
        page = min(max_page, page + 1)
        p = put_in(p, ["_flow", "servicesPage"], page)
        save(from, %{payload: p})
        reply({:multi, services_prompt(catalog, page), length(catalog)}, ctx)

      catalog == [] ->
        p = put_in(p, ["services", "servicesOffered"], [])
        advance_save(from, lead, p, "equipment")
        reply(equipment_qr(), ctx)

      true ->
        case Parse.parse_multi_select(message, length(catalog)) do
          sel when is_list(sel) and sel != [] ->
            offered =
              Enum.map(sel, fn i ->
                item = Enum.at(catalog, i - 1)
                %{"id" => item[:id] || item["id"], "name" => item[:name] || item["name"]}
              end)

            p = put_in(p, ["services", "servicesOffered"], offered)
            advance_save(from, lead, p, "equipment")
            reply(equipment_qr(), ctx)

          _ ->
            reply({:multi, services_prompt(catalog, page), length(catalog)}, ctx)
        end
    end
  end

  defp equipment(from, lead, p, message, ctx) do
    case Parse.equipment_choice(message) do
      nil ->
        reply(equipment_qr(), ctx)

      n ->
        opts = [
          "Yes, I have all necessary equipment",
          "I have some equipment",
          "No, I need equipment provided"
        ]

        p = put_in(p, ["services", "equipmentStatus"], Enum.at(opts, n - 1))
        advance_save(from, lead, p, "availability_days")
        reply({:multi, days_prompt(), 7}, ctx)
    end
  end

  defp availability_days(from, lead, p, message, cmd, ctx) do
    days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    cond do
      cmd == "SKIP" ->
        p = put_in(p, ["availability", "days"], [])
        advance_save(from, lead, p, "hours_per_week")
        reply({:menu, hours_prompt()}, ctx)

      sel = Parse.parse_multi_select(message, 7) ->
        p = put_in(p, ["availability", "days"], Enum.map(sel, &Enum.at(days, &1 - 1)))
        advance_save(from, lead, p, "hours_per_week")
        reply({:menu, hours_prompt()}, ctx)

      true ->
        reply({:multi, days_prompt(), 7}, ctx)
    end
  end

  defp preferred_shifts(from, lead, p, message, cmd, ctx) do
    labels = [
      "Morning, 6 AM – 12 PM",
      "Afternoon, 12 PM – 6 PM",
      "Evening, 6 PM – 10 PM",
      "Weekends only"
    ]

    cond do
      cmd == "SKIP" ->
        p = put_in(p, ["availability", "preferredShifts"], [])
        advance_save(from, lead, p, "start_date")
        reply({:text, start_prompt()}, ctx)

      sel = Parse.parse_multi_select(message, 4) ->
        p =
          put_in(p, ["availability", "preferredShifts"], Enum.map(sel, &Enum.at(labels, &1 - 1)))

        advance_save(from, lead, p, "start_date")
        reply({:text, start_prompt()}, ctx)

      true ->
        reply({:multi, shifts_prompt(), 4}, ctx)
    end
  end

  defp start_date(from, lead, p, message, ctx) do
    case Parse.parse_future_date(message) do
      nil ->
        reply({:text, "That date is not valid or is in the past.\n\n#{start_prompt()}"}, ctx)

      iso ->
        p = put_in(p, ["availability", "startDate"], iso)
        advance_save(from, lead, p, "work_areas")
        reply({:multi, work_areas_prompt(), length(work_area_list())}, ctx)
    end
  end

  defp work_areas(from, lead, p, message, ctx) do
    areas = work_area_list()

    case Parse.parse_multi_select(message, length(areas)) do
      sel when is_list(sel) and sel != [] ->
        p = put_in(p, ["availability", "workAreas"], Enum.map(sel, &Enum.at(areas, &1 - 1)))
        advance_save(from, lead, p, "office_cleaning_skill")
        reply(yes_no(@q_office), ctx)

      _ ->
        reply({:multi, work_areas_prompt(), length(areas)}, ctx)
    end
  end

  defp languages(from, lead, p, message, ctx, max, labels, none_n, path, next, next_reply, retry) do
    case Parse.parse_multi_select(message, max, none_option: none_n) do
      sel when is_list(sel) and sel != [] ->
        if none_n in sel and length(sel) > 1 do
          reply({:multi, retry <> "\n\nIf you pick None, use only #{none_n}.", max}, ctx)
        else
          chosen = sel |> Enum.map(&Enum.at(labels, &1 - 1)) |> Enum.reject(&(&1 == "None"))
          p = put_in(p, path, chosen)
          advance_save(from, lead, p, next)
          reply(next_reply, ctx)
        end

      _ ->
        reply({:multi, retry, max}, ctx)
    end
  end

  defp international_languages(from, lead, p, message, ctx) do
    labels = ["French", "Portuguese", "Spanish", "None"]

    case Parse.parse_multi_select(message, 4, none_option: 4) do
      sel when is_list(sel) and sel != [] ->
        if 4 in sel and length(sel) > 1 do
          reply({:multi, intl_lang_prompt() <> "\n\nIf None, use only 4.", 4}, ctx)
        else
          chosen = sel |> Enum.map(&Enum.at(labels, &1 - 1)) |> Enum.reject(&(&1 == "None"))
          p = put_in(p, ["skills", "internationalLanguages"], chosen)
          advance_save(from, lead, p, "terms_agreement")
          reply(accept_qr(@q_terms), ctx)
        end

      _ ->
        reply({:multi, intl_lang_prompt(), 4}, ctx)
    end
  end

  defp skip_ghana_to_terms(from, lead, ctx) do
    _lead = skip_retired_steps(from, lead)
    reply(accept_qr(@q_terms), ctx)
  end

  defp terms(from, lead, p, message, ctx) do
    if Parse.terms_accept?(message) do
      p =
        p
        |> put_in(["verification", "acceptedTerms"], true)
        |> put_in(["verification", "acceptedTermsAt"], DateTime.to_iso8601(DateTime.utc_now()))

      advance_save(from, lead, p, "background_check")
      reply(accept_qr(@q_background), ctx)
    else
      reply(
        accept_qr(
          @q_terms,
          "Please choose one:\n\n#{@q_terms}\n\n1. Accept\n2. Back (type BACK)\n3. Website (type WEB)"
        ),
        ctx
      )
    end
  end

  defp background(from, lead, p, message, ctx) do
    if Parse.background_consent?(message) do
      p =
        p
        |> put_in(["verification", "backgroundCheckConsent"], true)
        |> put_in(
          ["verification", "backgroundCheckConsentAt"],
          DateTime.to_iso8601(DateTime.utc_now())
        )

      advance_save(from, lead, p, "whatsapp_background_verify")

      background_link_reply(
        from,
        ctx,
        "One last step: verify your identity for your background check.\n\n"
      )
    else
      reply(
        accept_qr(
          @q_background,
          "Please choose one:\n\n#{@q_background}\n\n1. Accept\n2. Back (type BACK)\n3. Website (type WEB)"
        ),
        ctx
      )
    end
  end

  defp background_verify(from, lead, _p, message, cmd, ctx) do
    lower = String.downcase(String.trim(message))
    done? = lower in ["done", "finished", "ok", "complete", "completed"]

    cond do
      cmd == "LINK" ->
        background_link_reply(from, ctx, "Background check verification:\n")

      not done? ->
        reply(
          {:plain,
           "Finish your verification on the secure page, then reply DONE.\n\nReply LINK if you need a new verification link.\nReply SIGNUP if you need to sign in first."},
          ctx
        )

      true ->
        advance_save(from, lead, lead.payload, "review_submit")
        reply(submit_qr(review_summary(lead.payload)), ctx)
    end
  end

  defp review_submit(from, lead, p, cmd, ctx) do
    if cmd == "SUBMIT" do
      save(from, %{
        payload: p,
        current_step: "completed",
        step: "completed",
        status: "submitted_pending_signup",
        submitted_at: DateTime.utc_now()
      })

      Mithril.WhatsApp.Recruitment.Mirror.maybe_sync(lead.id)
      _ = Outbound.send_plain_text(ctx.to, ctx.from, "Processing your request…")
      reply({:plain, submitted_message("#{app_url()}/sign-in")}, ctx)
    else
      reply(
        submit_qr(
          review_summary(p),
          "Please choose one:\n\n#{review_summary(p)}\n\n1. Submit (type SUBMIT)\n2. Back (type BACK)\n3. Website (type WEB)\n4. Phone sign-in on web (type SIGNUP)"
        ),
        ctx
      )
    end
  end

  defp required_text(from, lead, p, message, ctx, path, next, next_msg, retry, opts \\ []) do
    if String.trim(message) == "" do
      reply({:text, retry}, ctx)
    else
      p = put_in(p, path, String.trim(message))
      extra = name_extra(p, opts) |> Map.merge(area_extra(p, opts))
      advance_save(from, lead, p, next, extra)
      reply({:text, next_msg}, ctx)
    end
  end

  defp skippable(from, lead, p, message, cmd, ctx, path, next, next_msg) do
    value = if cmd == "SKIP", do: "", else: String.trim(message)
    p = put_in(p, path, value)
    advance_save(from, lead, p, next)
    reply({:text, next_msg}, ctx)
  end

  defp phone_field(from, lead, p, message, ctx, path, next, next_reply, retry) do
    case Parse.normalize_ghana_phone(message) do
      nil ->
        reply({:text, retry}, ctx)

      phone ->
        p = put_in(p, path, phone)
        advance_save(from, lead, p, next)
        reply(next_reply, ctx)
    end
  end

  defp menu(from, lead, p, message, ctx, max, labels, path, next, next_reply, retry, opts \\ []) do
    case Parse.parse_menu_choice(message, max) do
      nil ->
        reply(if(opts[:quick?], do: next_reply_or_retry(retry), else: menu_or_text(retry)), ctx)

      n ->
        p = put_in(p, path, Enum.at(labels, n - 1))
        advance_save(from, lead, p, next)
        reply(next_reply, ctx)
    end
  end

  defp multi(from, lead, p, message, ctx, max, labels, path, next, next_reply, retry) do
    case Parse.parse_multi_select(message, max) do
      sel when is_list(sel) and sel != [] ->
        p = put_in(p, path, Enum.map(sel, &Enum.at(labels, &1 - 1)))
        advance_save(from, lead, p, next)
        reply(next_reply, ctx)

      _ ->
        reply({:multi, retry, max}, ctx)
    end
  end

  defp yes_no_branch(from, lead, p, message, ctx, yes_step, no_step, yes_msg, no_reply, question) do
    case Parse.yes_no_choice(message) do
      nil ->
        reply(yes_no(question, "Please choose one:\n\n#{question}\n\n1. Yes\n2. No"), ctx)

      2 ->
        advance_save(from, lead, p, no_step)
        reply(no_reply, ctx)

      _ ->
        advance_save(from, lead, p, yes_step)
        reply({:text, yes_msg}, ctx)
    end
  end

  defp yes_no_set(from, lead, p, message, ctx, path, next, next_reply, question) do
    case Parse.yes_no_choice(message) do
      nil ->
        reply(yes_no(question, "Please choose one:\n\n#{question}\n\n1. Yes\n2. No"), ctx)

      n ->
        p = put_in(p, path, n == 1)
        advance_save(from, lead, p, next)
        reply(next_reply, ctx)
    end
  end

  defp prompt(lead, ctx) do
    p = lead.payload

    case lead.current_step do
      "awaiting_apply" ->
        reply(welcome(), ctx)

      "personal_email" ->
        reply({:text, "What is your email address?\n\nReply SKIP to add it later."}, ctx)

      "personal_first_name" ->
        reply({:text, "What is your first name?"}, ctx)

      "personal_last_name" ->
        reply({:text, "What is your last name?"}, ctx)

      "personal_address" ->
        reply({:text, @address_prompt}, ctx)

      "personal_city_area" ->
        reply({:menu, city_prompt()}, ctx)

      "personal_city_other" ->
        reply({:text, "Which area? (free text)"}, ctx)

      "personal_bio" ->
        reply(
          {:text, "Tell customers about yourself (max 500 chars).\n\nReply SKIP to add later."},
          ctx
        )

      "experience_has_cleaned" ->
        reply(yes_no(@q_prior), ctx)

      "years_of_experience" ->
        reply({:menu, years_prompt()}, ctx)

      "previous_employers" ->
        reply({:text, "Where have you worked before?\n\nReply SKIP if not applicable."}, ctx)

      "ref1_name" ->
        reply({:text, "Provide a name for your reference: what is their name?"}, ctx)

      "ref1_contact" ->
        reply(
          {:text,
           "Provide a phone number for your reference: what is their phone number?\nExample: +233 55 123 4567"},
          ctx
        )

      "ref1_relationship" ->
        reply({:menu, relationship_prompt(1)}, ctx)

      "ask_ref2" ->
        reply(yes_no(@q_ref2), ctx)

      "ref2_name" ->
        reply({:text, "Reference 2: name?"}, ctx)

      "ref2_contact" ->
        reply({:text, "Reference 2 phone?"}, ctx)

      "ref2_relationship" ->
        reply({:menu, relationship_prompt(nil)}, ctx)

      "ask_ref3" ->
        reply(yes_no(@q_ref3), ctx)

      "ref3_name" ->
        reply({:text, "Reference 3: name?"}, ctx)

      "ref3_contact" ->
        reply({:text, "Reference 3 phone?"}, ctx)

      "ref3_relationship" ->
        reply({:menu, relationship_prompt(nil)}, ctx)

      "client_description" ->
        reply({:menu, client_desc_prompt()}, ctx)

      "specializations" ->
        reply({:multi, spec_prompt(), 5}, ctx)

      "certifications" ->
        reply({:text, "Certifications or training?\n\nReply SKIP if none."}, ctx)

      "services_offered" ->
        catalog = get_in(p, ["_flow", "serviceCatalog"]) || []
        page = get_in(p, ["_flow", "servicesPage"]) || 0
        reply({:multi, services_prompt(catalog, page), max(length(catalog), 1)}, ctx)

      "equipment" ->
        reply(equipment_qr(), ctx)

      "availability_days" ->
        reply({:multi, days_prompt(), 7}, ctx)

      "hours_per_week" ->
        reply({:menu, hours_prompt()}, ctx)

      "preferred_shifts" ->
        reply({:multi, shifts_prompt(), 4}, ctx)

      "start_date" ->
        reply({:text, start_prompt()}, ctx)

      "work_areas" ->
        reply({:multi, work_areas_prompt(), length(work_area_list())}, ctx)

      "office_cleaning_skill" ->
        reply(yes_no(@q_office), ctx)

      "ironing_confidence" ->
        reply({:menu, confidence_prompt("Ironing")}, ctx)

      "laundry_confidence" ->
        reply({:menu, confidence_prompt("Laundry")}, ctx)

      "pets" ->
        reply({:menu, pets_prompt()}, ctx)

      "cooking_course" ->
        reply(yes_no(@q_cook), ctx)

      "drivers_license" ->
        reply(yes_no(@q_license), ctx)

      "local_languages" ->
        reply({:multi, local_lang_prompt(), 5}, ctx)

      "international_languages" ->
        reply({:multi, intl_lang_prompt(), 4}, ctx)

      "ghana_card_front" ->
        reply(accept_qr(@q_terms), ctx)

      "ghana_card_back" ->
        reply(accept_qr(@q_terms), ctx)

      "terms_agreement" ->
        reply(accept_qr(@q_terms), ctx)

      "background_check" ->
        reply(accept_qr(@q_background), ctx)

      "whatsapp_background_verify" ->
        background_link_reply(lead.phone, ctx, "Background check verification:\n")

      "review_submit" ->
        reply(submit_qr(review_summary(p)), ctx)

      "completed" ->
        reply(
          {:plain,
           "Your application draft is saved ✅\n\nReply SIGNUP to sign in with your phone and continue verification on the web.\nReply WEB if you prefer to open the website with a continue code.\n\n#{app_url()}/join-as-cleaner"},
          ctx
        )

      _ ->
        reply({:text, "Something went wrong with your session. Reply RESTART or HELP."}, ctx)
    end
  end

  defp code_reply(from, join_url, ctx) do
    case Leads.issue_continuation_code(from) do
      {:ok, %{display: display}} ->
        reply(
          {:plain,
           "Your web continue code:\n\n#{display}\n\nPaste it on Join as Cleaner when you're asked for your WhatsApp code.\n\nOr open this link (your code is included):\n#{join_url}?apply=1&continue=#{URI.encode_www_form(display)}\n\nOne-time use: it stops working after the site loads your answers. If you never use it, it expires after 7 days. Reply CODE or WEB for a new one."},
          ctx
        )

      _ ->
        reply(
          {:plain,
           "We could not create a continue code right now. Please try again in a moment, or reply WEB."},
          ctx
        )
    end
  end

  defp signup_reply(from, lead, ctx) do
    pi = lead.payload["personalInfo"] || %{}
    full_name = String.trim("#{pi["firstName"]} #{pi["lastName"]}")

    signup_phone =
      Parse.normalize_ghana_phone(pi["phone"] || "") || Parse.normalize_ghana_phone(from) || from

    case Leads.issue_continuation_code(from) do
      {:ok, %{display: display}} ->
        return_path =
          if lead.current_step == "whatsapp_background_verify" do
            "/join-as-cleaner/whatsapp-background-check?continue=#{URI.encode_www_form(display)}"
          else
            "/join-as-cleaner?apply=1&continue=#{URI.encode_www_form(display)}"
          end

        q =
          URI.encode_query(
            %{"returnUrl" => return_path, "phone" => signup_phone}
            |> maybe_name(full_name)
          )

        link = "#{app_url()}/sign-up?#{q}"

        extra =
          if lead.current_step == "whatsapp_background_verify",
            do:
              "After signing in, your background-check page will open. When you finish, reply DONE here.",
            else: "After signing in, you can complete your verification."

        reply(
          {:plain,
           "Continue with phone sign-in here:\n\n#{link}\n\nUse the same phone number you used on WhatsApp so we can find your saved application.\n\n#{extra}"},
          ctx
        )

      _ ->
        reply(
          {:plain,
           "We could not create a continue link. Please try again in a moment, or reply WEB or CODE."},
          ctx
        )
    end
  end

  defp background_link_reply(phone, ctx, prefix) do
    case Leads.issue_continuation_code(phone) do
      {:ok, %{display: display}} ->
        link =
          "#{app_url()}/join-as-cleaner/whatsapp-background-check?continue=#{URI.encode_www_form(display)}"

        reply(
          {:plain,
           "#{prefix}#{if String.contains?(prefix, "http"), do: "", else: "Open this secure verification page:\n"}#{link}\n\nReply DONE after you finish, or LINK for a new link."},
          ctx
        )

      _ ->
        reply(
          {:plain,
           "We could not create your verification link. Please try again in a moment, or reply LINK."},
          ctx
        )
    end
  end

  defp reset_unknown_step(from, lead) do
    if Payload.known_step?(lead.current_step) do
      lead
    else
      patch = %{
        current_step: "awaiting_apply",
        step: "awaiting_apply",
        step_history: [],
        payload: lead.payload,
        status: "new"
      }

      save(from, patch)
      Map.merge(lead, patch)
    end
  end

  defp skip_retired_steps(from, lead) do
    history =
      lead.step_history
      |> List.wrap()
      |> Enum.reject(&Payload.retired_step?/1)

    cond do
      Payload.retired_step?(lead.current_step) ->
        patch = %{current_step: "terms_agreement", step: "terms_agreement", step_history: history}
        save(from, patch)
        Map.merge(lead, patch)

      history != List.wrap(lead.step_history) ->
        patch = %{step_history: history}
        save(from, patch)
        Map.merge(lead, patch)

      true ->
        lead
    end
  end

  defp advance_save(from, lead, p, next, extra \\ %{}) do
    save(from, Map.merge(Payload.advance(lead, next), Map.merge(%{payload: p}, extra)))
  end

  defp save(phone, patch) do
    case Leads.persist(phone, patch) do
      :ok -> :ok
      {:error, error} -> Logger.error("whatsapp recruitment persist failed #{inspect(error)}")
    end
  end

  defp reply(message, ctx) do
    {:xml, xml} = Outbound.send_reply(normalize_reply(message), ctx)
    xml
  end

  defp normalize_reply({:quick, _} = reply), do: reply
  defp normalize_reply({:text, _} = reply), do: reply
  defp normalize_reply({:menu, _} = reply), do: reply
  defp normalize_reply({:multi, _, _} = reply), do: reply
  defp normalize_reply({:plain, _} = reply), do: reply
  defp normalize_reply(text) when is_binary(text), do: {:text, text}

  defp welcome(prefix \\ "") do
    body =
      if(prefix == "", do: "", else: prefix <> "\n\n") <>
        "Hi 👋 Welcome to Instaclean cleaner recruitment.\n\nYou can complete the first part right here on WhatsApp.\n\nTap Apply to start.\nTap Website only if you prefer to continue in your browser."

    fallback =
      if(prefix == "", do: "", else: prefix <> "\n\n") <>
        "Hi 👋 Welcome to Instaclean cleaner recruitment.\n\nYou can complete the first part right here on WhatsApp.\n\nReply APPLY to start.\nReply HELP if you need help.\nReply WEB only if you prefer to continue in your browser."

    quick(
      :welcome,
      body,
      [
        %{id: "APPLY", title: "Apply"},
        %{id: "HELP", title: "Help"},
        %{id: "WEB", title: "Website"}
      ],
      fallback
    )
  end

  defp yes_no(message, fallback \\ nil) do
    quick(
      :yes_no,
      message,
      [%{id: "1", title: "Yes"}, %{id: "2", title: "No"}, %{id: "WEB", title: "Website"}],
      fallback
    )
  end

  defp accept_qr(message, fallback \\ nil) do
    quick(
      :accept,
      message,
      [%{id: "1", title: "Accept"}, %{id: "BACK", title: "Back"}, %{id: "WEB", title: "Website"}],
      fallback
    )
  end

  defp submit_qr(message, fallback \\ nil) do
    quick(
      :submit,
      message,
      [
        %{id: "SUBMIT", title: "Submit"},
        %{id: "BACK", title: "Back"},
        %{id: "WEB", title: "Website"}
      ],
      fallback
    )
  end

  defp equipment_qr do
    quick(
      :equipment,
      @q_equipment,
      [
        %{id: "1", title: "All equipment"},
        %{id: "2", title: "Some"},
        %{id: "3", title: "Need provided"}
      ],
      nil
    )
  end

  defp quick(template, message, buttons, fallback) do
    {:quick, %{template: template, message: message, buttons: buttons, fallback: fallback}}
  end

  defp city_prompt do
    lines =
      Payload.areas()
      |> Enum.with_index(1)
      |> Enum.map(fn {area, i} -> "#{i}. #{area}" end)
      |> Enum.join("\n")

    "Which city or area are you in?\n\nReply with a number:\n#{lines}"
  end

  defp years_prompt,
    do:
      "Years of experience?\n1. Less than 1 year\n2. 1–2 years\n3. 3–5 years\n4. More than 5 years"

  defp relationship_prompt(1),
    do:
      "Relationship with Reference 1?\n1. Client\n2. Employer\n3. Supervisor\n4. Family Friend\n5. Colleague"

  defp relationship_prompt(_),
    do: "Relationship?\n1. Client\n2. Employer\n3. Supervisor\n4. Family Friend\n5. Colleague"

  defp client_desc_prompt,
    do:
      "How would clients describe you?\n1. Reliable and punctual\n2. Friendly and respectful\n3. Thorough and detail-oriented\n4. Professional and trustworthy\n5. Fast and efficient"

  defp client_desc_opts,
    do: [
      "Reliable and punctual",
      "Friendly and respectful",
      "Thorough and detail-oriented",
      "Professional and trustworthy",
      "Fast and efficient"
    ]

  defp spec_prompt,
    do:
      "Specializations:\n1. Residential\n2. Commercial/office\n3. Window cleaning\n4. Carpet cleaning\n5. Pressure washing"

  defp spec_opts,
    do: [
      "Residential",
      "Commercial/office",
      "Window cleaning",
      "Carpet cleaning",
      "Pressure washing"
    ]

  defp days_prompt,
    do:
      "Available days?\n1. Monday\n2. Tuesday\n3. Wednesday\n4. Thursday\n5. Friday\n6. Saturday\n7. Sunday\n\nReply SKIP to decide later."

  defp hours_prompt, do: "Hours per week?\n1. <10\n2. 10–20\n3. 20–40\n4. 40+ / full-time"

  defp shifts_prompt,
    do:
      "Preferred shifts?\n1. Morning 6–12\n2. Afternoon 12–6\n3. Evening 6–10\n4. Weekends only\n\nReply SKIP if no preference."

  defp start_prompt,
    do: "When can you start? Reply with a date (e.g. 15 June 2026), or type TODAY or TOMORROW."

  defp work_area_list, do: Enum.reject(Payload.areas(), &(&1 == "Other"))

  defp work_areas_prompt do
    lines =
      work_area_list()
      |> Enum.with_index(1)
      |> Enum.map(fn {area, i} -> "#{i}. #{area}" end)
      |> Enum.join("\n")

    "Areas you can reach by public transport?\n#{lines}"
  end

  defp confidence_prompt(kind),
    do: "#{kind} confidence?\n1. Very confident\n2. Somewhat confident\n3. Still learning"

  defp confidence_opts, do: ["Very confident", "Somewhat confident", "Still learning"]

  defp pets_prompt,
    do: "Pets in homes?\n1. Yes, dogs\n2. Yes, cats\n3. Both\n4. No, pet-free only"

  defp pets_opts,
    do: ["Yes, with dogs", "Yes, with cats", "Both dogs and cats", "No, I prefer pet-free homes"]

  defp local_lang_prompt, do: "Local languages?\n1. Twi\n2. Ga\n3. Ewe\n4. Hausa\n5. None"

  defp intl_lang_prompt,
    do: "International languages?\n1. French\n2. Portuguese\n3. Spanish\n4. None"

  defp services_prompt([], _page),
    do: "No services found in catalog. Reply SKIP to continue (contact support)."

  defp services_prompt(catalog, page) do
    start = page * 8
    slice = Enum.slice(catalog, start, 8)

    lines =
      slice
      |> Enum.with_index(start + 1)
      |> Enum.map(fn {item, i} ->
        name = item[:name] || item["name"]
        category = item[:category] || item["category"] || "Services"
        "#{i}. #{name} (#{category})"
      end)
      |> Enum.join("\n")

    more = if start + 8 < length(catalog), do: "\n\nReply MORE for more services.", else: ""
    "Which services can you offer?\n\n#{lines}#{more}"
  end

  defp status_message(lead, join_url) do
    steps = Payload.steps()
    idx = Enum.find_index(steps, &(&1 == lead.current_step)) || 0
    total = length(steps) - 1
    pct = round(idx / total * 100)

    "Progress: ~#{pct}% (step #{idx + 1} of ~#{total + 1})\nCurrent: #{lead.current_step}\nReply HELP for commands.\n\nStop anytime. Reply CODE for your web continue code, or WEB:\n#{join_url}"
  end

  defp review_summary(p) do
    exp =
      if get_in(p, ["experience", "hasExperience"]) == false,
        do: "No prior experience",
        else: get_in(p, ["experience", "yearsOfExperience"]) || "—"

    svc =
      case get_in(p, ["services", "servicesOffered"]) do
        list when is_list(list) and list != [] ->
          Enum.map_join(list, ", ", &(&1["name"] || &1[:name]))

        _ ->
          "—"
      end

    areas =
      case get_in(p, ["availability", "workAreas"]) do
        list when is_list(list) and list != [] -> Enum.join(list, ", ")
        _ -> "—"
      end

    pi = p["personalInfo"] || %{}

    "Review your application:\n\nName: #{pi["firstName"]} #{pi["lastName"]}\nPhone: #{mask(pi["phone"])}\nArea: #{pi["city"]}\nExperience: #{exp}\nServices: #{svc}\nWork areas: #{areas}\n\nReply SUBMIT to save your draft.\nReply BACK to edit the previous step.\nReply RESTART to start over.\nReply SIGNUP for phone sign-in on the web, or WEB to open the site."
  end

  defp submitted_message(sign_in) do
    support =
      Application.get_env(
        :mithril,
        :recruitment_mirror_support_email,
        "support@tryinstaclean.com"
      )

    "Your application draft has been submitted for review. Please allow 24–48 hours while we review your application.\n\nOpen the website with your phone number or email to log in:\n#{sign_in}\n\nIf you have any issues signing in, email #{support} or open our help chat on the website:\n#{app_url()}/?openBeacon=1\n\nWe are excited to have you onboard! ✨"
  end

  defp mask(phone) when is_binary(phone) do
    digits = String.replace(phone, ~r/\D/, "")
    if String.length(digits) <= 4, do: "****", else: "****" <> String.slice(digits, -4, 4)
  end

  defp mask(_), do: "****"

  defp admin_line?(e164) do
    configured =
      (Application.get_env(:mithril, :twilio_whatsapp_admin_from) || "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    list = if configured == [], do: @admin_default, else: configured
    Parse.normalize_ghana_phone(e164) in Enum.map(list, &Parse.normalize_ghana_phone/1)
  end

  defp app_url do
    (Application.get_env(:mithril, :app_url) || "https://tryinstaclean.com")
    |> String.trim_trailing("/")
  end

  defp coords(params) do
    lat = Parse.string_param(params, "Latitude")
    lng = Parse.string_param(params, "Longitude")

    with {la, _} <- Float.parse(lat),
         {ln, _} <- Float.parse(lng) do
      {la, ln}
    else
      _ -> {nil, nil}
    end
  end

  defp maybe_put_address(p, message, lat, lng) do
    cond do
      String.trim(message) != "" -> put_in(p, ["personalInfo", "address"], String.trim(message))
      lat && lng -> put_in(p, ["personalInfo", "address"], "Shared WhatsApp location")
      true -> p
    end
  end

  defp maybe_put_coords(p, lat, lng) when is_number(lat) and is_number(lng) do
    put_in(p, ["personalInfo", "locationCoordinates"], %{"latitude" => lat, "longitude" => lng})
  end

  defp maybe_put_coords(p, _, _), do: p

  defp name_extra(p, opts) do
    if opts[:name?] do
      %{
        name:
          String.trim(
            "#{get_in(p, ["personalInfo", "firstName"])} #{get_in(p, ["personalInfo", "lastName"])}"
          )
      }
    else
      %{}
    end
  end

  defp area_extra(p, opts) do
    if opts[:area?], do: %{area: get_in(p, ["personalInfo", "city"])}, else: %{}
  end

  defp next_reply_or_retry(retry) when is_binary(retry), do: {:menu, retry}
  defp next_reply_or_retry(retry), do: retry

  defp menu_or_text(retry) when is_binary(retry), do: {:menu, retry}
  defp menu_or_text(retry), do: retry

  defp maybe_name(query, ""), do: query
  defp maybe_name(query, name), do: Map.put(query, "name", name)
end
