defmodule MithrilWeb.Schemas.Direct do
  @moduledoc "OpenAPI schemas for the Instaclean Direct API."

  defmodule CreatePlacementRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCreatePlacementRequest",
      type: :object,
      properties: %{
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
        },
        livingArrangement: %Schema{type: :string, enum: ~w(live_in live_out flexible)},
        employmentType: %Schema{type: :string, enum: ~w(full_time part_time flexible)},
        desiredStartDate: %Schema{type: :string, format: :date, nullable: true},
        salaryMinPesewas: %Schema{type: :integer, minimum: 0, nullable: true},
        salaryMaxPesewas: %Schema{type: :integer, minimum: 0, nullable: true},
        salaryFrequency: %Schema{
          type: :string,
          enum: ~w(hourly daily weekly monthly),
          nullable: true
        },
        householdAddress: %Schema{type: :string, minLength: 3},
        requirements: %Schema{type: :object, additionalProperties: true, default: %{}},
        notes: %Schema{type: :string, nullable: true}
      },
      required: [:role, :livingArrangement, :employmentType, :householdAddress]
    })
  end

  defmodule CreatePlacementResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCreatePlacementResponse",
      type: :object,
      properties: %{id: %Schema{type: :string, format: :uuid}},
      required: [:id]
    })
  end

  defmodule PlacementListItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPlacementListItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ~w(submitted matching shortlisted placed cancelled expired)
        },
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
        },
        livingArrangement: %Schema{type: :string, enum: ~w(live_in live_out flexible)},
        employmentType: %Schema{type: :string, enum: ~w(full_time part_time flexible)},
        desiredStartDate: %Schema{type: :string, format: :date, nullable: true},
        householdAddress: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :status,
        :role,
        :livingArrangement,
        :employmentType,
        :desiredStartDate,
        :householdAddress,
        :createdAt
      ]
    })
  end

  defmodule PlacementListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.PlacementListItem
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPlacementListResponse",
      type: :object,
      properties: %{
        placements: %Schema{type: :array, items: PlacementListItem}
      },
      required: [:placements]
    })
  end

  defmodule PlacementSummary do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPlacementSummary",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
        },
        status: %Schema{
          type: :string,
          enum: ~w(submitted matching shortlisted placed cancelled expired)
        },
        householdAddress: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :role, :status, :householdAddress, :createdAt]
    })
  end

  defmodule CandidateCard do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectCandidateCard",
      type: :object,
      properties: %{
        matchId: %Schema{type: :string, format: :uuid},
        candidateUserId: %Schema{type: :string, format: :uuid},
        firstName: %Schema{type: :string},
        lastInitial: %Schema{type: :string},
        avatarUrl: %Schema{type: :string, nullable: true},
        yearsExperience: %Schema{type: :integer, nullable: true},
        bio: %Schema{type: :string, nullable: true},
        preferredLanguages: %Schema{type: :array, items: %Schema{type: :string}},
        availableFrom: %Schema{type: :string, format: :date, nullable: true},
        rating: %Schema{type: :number, nullable: true},
        completedJobs: %Schema{type: :integer, nullable: true},
        customerVisibleNote: %Schema{type: :string, nullable: true},
        identityVerified: %Schema{type: :boolean},
        providerVerified: %Schema{type: :boolean},
        matchStatus: %Schema{
          type: :string,
          enum: ~w(suggested selected rejected cancelled hired)
        }
      },
      required: [
        :matchId,
        :candidateUserId,
        :firstName,
        :lastInitial,
        :avatarUrl,
        :yearsExperience,
        :bio,
        :preferredLanguages,
        :availableFrom,
        :rating,
        :completedJobs,
        :customerVisibleNote,
        :identityVerified,
        :providerVerified,
        :matchStatus
      ]
    })
  end

  defmodule PlacementDetailResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.{CandidateCard, PlacementSummary}
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPlacementDetailResponse",
      type: :object,
      properties: %{
        placement: PlacementSummary,
        candidates: %Schema{type: :array, items: CandidateCard}
      },
      required: [:placement, :candidates]
    })
  end

  defmodule PrivateHelperRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectPrivateHelperRequest",
      type: :object,
      properties: %{
        firstName: %Schema{type: :string, minLength: 1},
        lastName: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, minLength: 6},
        email: %Schema{type: :string, nullable: true},
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener),
          nullable: true
        },
        startDate: %Schema{type: :string, format: :date, nullable: true},
        liveIn: %Schema{type: :boolean, default: false}
      },
      required: [:firstName, :phone]
    })
  end

  defmodule HelperListItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectHelperListItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        firstName: %Schema{type: :string},
        lastName: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string},
        source: %Schema{type: :string, enum: ~w(instaclean_placement customer_invited)},
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener),
          nullable: true
        },
        status: %Schema{type: :string},
        liveIn: %Schema{type: :boolean}
      },
      required: [:id, :firstName, :lastName, :phone, :source, :role, :status, :liveIn]
    })
  end

  defmodule HelperListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.HelperListItem
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectHelperListResponse",
      type: :object,
      properties: %{helpers: %Schema{type: :array, items: HelperListItem}},
      required: [:helpers]
    })
  end

  defmodule HouseholdWorkerResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectHouseholdWorkerResponse",
      type: :object,
      properties: %{householdWorkerId: %Schema{type: :string, format: :uuid}},
      required: [:householdWorkerId]
    })
  end

  defmodule AdminPlacement do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPlacement",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        customerUserId: %Schema{type: :string, format: :uuid},
        status: %Schema{
          type: :string,
          enum: ~w(submitted matching shortlisted placed cancelled expired)
        },
        role: %Schema{
          type: :string,
          enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
        },
        householdAddress: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :customerUserId, :status, :role, :householdAddress, :createdAt]
    })
  end

  defmodule AdminPlacementsResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.AdminPlacement
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminPlacementsResponse",
      type: :object,
      properties: %{placements: %Schema{type: :array, items: AdminPlacement}},
      required: [:placements]
    })
  end

  defmodule AdminCandidate do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCandidate",
      type: :object,
      properties: %{
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        rating: %Schema{type: :number, nullable: true},
        completedJobs: %Schema{type: :integer, nullable: true},
        placementOptIn: %Schema{type: :boolean},
        placementStatus: %Schema{type: :string},
        desiredRoles: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: ~w(househelp nanny cleaner elder_caregiver cook driver gardener)
          }
        }
      },
      required: [
        :userId,
        :name,
        :email,
        :rating,
        :completedJobs,
        :placementOptIn,
        :placementStatus,
        :desiredRoles
      ]
    })
  end

  defmodule AdminCandidatesResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.AdminCandidate
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCandidatesResponse",
      type: :object,
      properties: %{candidates: %Schema{type: :array, items: AdminCandidate}},
      required: [:candidates]
    })
  end

  defmodule AdminMatchRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminMatchRequest",
      type: :object,
      properties: %{
        candidateUserId: %Schema{type: :string, format: :uuid},
        customerVisibleNote: %Schema{type: :string, nullable: true},
        consentConfirmed: %Schema{type: :boolean, default: false}
      },
      required: [:candidateUserId]
    })
  end

  defmodule AdminMatchResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminMatchResponse",
      type: :object,
      properties: %{matchId: %Schema{type: :string, format: :uuid}},
      required: [:matchId]
    })
  end
end
