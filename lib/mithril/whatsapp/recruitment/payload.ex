defmodule Mithril.WhatsApp.Recruitment.Payload do
  @moduledoc false

  def steps do
    [
      "awaiting_apply",
      "personal_email",
      "personal_first_name",
      "personal_last_name",
      "personal_address",
      "personal_city_area",
      "personal_city_other",
      "personal_bio",
      "experience_has_cleaned",
      "years_of_experience",
      "previous_employers",
      "ref1_name",
      "ref1_contact",
      "ref1_relationship",
      "ask_ref2",
      "ref2_name",
      "ref2_contact",
      "ref2_relationship",
      "ask_ref3",
      "ref3_name",
      "ref3_contact",
      "ref3_relationship",
      "client_description",
      "specializations",
      "certifications",
      "services_offered",
      "equipment",
      "availability_days",
      "hours_per_week",
      "preferred_shifts",
      "start_date",
      "work_areas",
      "office_cleaning_skill",
      "ironing_confidence",
      "laundry_confidence",
      "pets",
      "cooking_course",
      "drivers_license",
      "local_languages",
      "international_languages",
      "ghana_card_front",
      "ghana_card_back",
      "terms_agreement",
      "background_check",
      "whatsapp_background_verify",
      "review_submit",
      "completed"
    ]
  end

  def skip_allowed?,
    do:
      MapSet.new([
        "personal_email",
        "personal_bio",
        "previous_employers",
        "certifications",
        "availability_days",
        "preferred_shifts"
      ])

  def areas do
    [
      "East Legon",
      "Airport Hills",
      "Cantonments",
      "Ridge",
      "Tse Addo",
      "Spintex",
      "Labone",
      "Airport",
      "Osu",
      "West Legon",
      "North Legon",
      "Haatso",
      "Other"
    ]
  end

  def default do
    %{
      "personalInfo" => %{
        "phone" => "",
        "email" => nil,
        "firstName" => "",
        "lastName" => "",
        "address" => "",
        "city" => "",
        "bio" => ""
      },
      "experience" => %{
        "hasExperience" => nil,
        "yearsOfExperience" => "",
        "previousEmployers" => "",
        "clientDescription" => ""
      },
      "references" => %{
        "client1Name" => "",
        "client1Contact" => "",
        "client1Relationship" => "",
        "client2Name" => "",
        "client2Contact" => "",
        "client2Relationship" => "",
        "client3Name" => "",
        "client3Contact" => "",
        "client3Relationship" => ""
      },
      "services" => %{
        "specializations" => [],
        "certifications" => "",
        "servicesOffered" => [],
        "equipmentStatus" => ""
      },
      "availability" => %{
        "days" => [],
        "hoursPerWeek" => "",
        "preferredShifts" => [],
        "startDate" => "",
        "workAreas" => []
      },
      "skills" => %{
        "cleanedOffices" => nil,
        "ironingConfidence" => "",
        "laundryConfidence" => "",
        "petComfort" => "",
        "cookingCourse" => nil,
        "driversLicense" => nil,
        "localLanguages" => [],
        "internationalLanguages" => []
      },
      "verification" => %{
        "ghanaCardFrontPath" => "",
        "ghanaCardBackPath" => "",
        "acceptedTerms" => false,
        "acceptedTermsAt" => "",
        "backgroundCheckConsent" => false,
        "backgroundCheckConsentAt" => ""
      },
      "_flow" => %{"servicesPage" => 0}
    }
  end

  def merge(raw) when is_map(raw) do
    d = default()

    d
    |> Map.merge(stringify_keys(raw))
    |> Map.put("personalInfo", Map.merge(d["personalInfo"], nested(raw, "personalInfo")))
    |> Map.put("experience", Map.merge(d["experience"], nested(raw, "experience")))
    |> Map.put("references", Map.merge(d["references"], nested(raw, "references")))
    |> Map.put("services", Map.merge(d["services"], nested(raw, "services")))
    |> Map.put("availability", Map.merge(d["availability"], nested(raw, "availability")))
    |> Map.put("skills", Map.merge(d["skills"], nested(raw, "skills")))
    |> Map.put("verification", Map.merge(d["verification"], nested(raw, "verification")))
    |> Map.put("_flow", Map.merge(d["_flow"], nested(raw, "_flow")))
    |> put_in(
      ["personalInfo", "email"],
      Mithril.WhatsApp.Recruitment.Parse.normalize_email(
        get_in(nested(raw, "personalInfo"), ["email"])
      )
    )
  end

  def merge(_), do: default()

  def advance(lead, next_step) do
    history = List.wrap(lead.step_history) ++ [lead.current_step]
    %{step_history: history, current_step: next_step, step: next_step}
  end

  def go_back(lead) do
    case Enum.reject(List.wrap(lead.step_history), &retired_step?/1) do
      [] ->
        nil

      history ->
        prev = List.last(history)
        %{step_history: Enum.drop(history, -1), current_step: prev, step: prev}
    end
  end

  def known_step?(step), do: step in steps()

  def retired_step?(step), do: step in ["ghana_card_front", "ghana_card_back"]

  defp nested(raw, key) do
    stringify_keys(Map.get(stringify_keys(raw), key, %{}))
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(_), do: %{}
end
