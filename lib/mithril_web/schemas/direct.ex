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
        customerName: %Schema{type: :string},
        customerEmail: %Schema{type: :string, nullable: true},
        customerPhone: %Schema{type: :string, nullable: true},
        livingArrangement: %Schema{
          type: :string,
          enum: ~w(live_in live_out flexible)
        },
        employmentType: %Schema{
          type: :string,
          enum: ~w(full_time part_time flexible)
        },
        desiredStartDate: %Schema{type: :string, format: :date, nullable: true},
        salaryMinPesewas: %Schema{type: :integer, nullable: true},
        salaryMaxPesewas: %Schema{type: :integer, nullable: true},
        salaryFrequency: %Schema{
          type: :string,
          enum: ~w(hourly daily weekly monthly),
          nullable: true
        },
        notes: %Schema{type: :string, nullable: true},
        shortlistCount: %Schema{type: :integer, minimum: 0},
        shortlistUserIds: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid}
        },
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :customerUserId,
        :customerName,
        :customerEmail,
        :customerPhone,
        :status,
        :role,
        :livingArrangement,
        :employmentType,
        :desiredStartDate,
        :salaryMinPesewas,
        :salaryMaxPesewas,
        :salaryFrequency,
        :notes,
        :shortlistCount,
        :shortlistUserIds,
        :householdAddress,
        :createdAt
      ]
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

  defmodule AdminCleanerApplication do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApplication",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string},
        kycStatus: %Schema{type: :string},
        hourlyRateGhs: %Schema{type: :number},
        skills: %Schema{type: :array, items: %Schema{type: :string}},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [
        :id,
        :userId,
        :name,
        :email,
        :phone,
        :status,
        :kycStatus,
        :hourlyRateGhs,
        :skills,
        :createdAt
      ]
    })
  end

  defmodule AdminCleanerApplicationDetail do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApplicationDetail",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        userId: %Schema{type: :string, format: :uuid, nullable: true},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string},
        kycStatus: %Schema{type: :string},
        hourlyRateGhs: %Schema{type: :number},
        skills: %Schema{type: :array, items: %Schema{type: :string}},
        createdAt: %Schema{type: :string, format: :"date-time", nullable: true},
        bio: %Schema{type: :string, nullable: true},
        applicantBio: %Schema{type: :string, nullable: true},
        languages: %Schema{type: :array, items: %Schema{type: :string}},
        serviceAreas: %Schema{type: :array, items: %Schema{type: :string}},
        yearsOfExperience: %Schema{type: :string, nullable: true},
        hoursPerWeek: %Schema{type: :string, nullable: true},
        certifications: %Schema{type: :array, items: %Schema{type: :string}},
        adminFeedback: %Schema{type: :string, nullable: true}
      },
      required: [
        :id,
        :userId,
        :name,
        :email,
        :phone,
        :status,
        :kycStatus,
        :hourlyRateGhs,
        :skills,
        :createdAt,
        :bio,
        :applicantBio,
        :languages,
        :serviceAreas,
        :yearsOfExperience,
        :hoursPerWeek,
        :certifications,
        :adminFeedback
      ]
    })
  end

  defmodule AdminCleanerApplicationListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.AdminCleanerApplication
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApplicationListResponse",
      type: :object,
      properties: %{applications: %Schema{type: :array, items: AdminCleanerApplication}},
      required: [:applications]
    })
  end

  defmodule AdminCleanerApplicationDraft do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApplicationDraft",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        currentStep: %Schema{type: :integer},
        createdAt: %Schema{type: :string, format: :"date-time"},
        updatedAt: %Schema{type: :string, format: :"date-time"},
        lastSavedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [
        :id,
        :userId,
        :name,
        :email,
        :phone,
        :currentStep,
        :createdAt,
        :updatedAt,
        :lastSavedAt
      ]
    })
  end

  defmodule AdminCleanerApplicationDraftDetail do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApplicationDraftDetail",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        userId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        currentStep: %Schema{type: :integer},
        createdAt: %Schema{type: :string, format: :"date-time"},
        updatedAt: %Schema{type: :string, format: :"date-time"},
        lastSavedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        city: %Schema{type: :string, nullable: true},
        bio: %Schema{type: :string, nullable: true},
        hoursPerWeek: %Schema{type: :string, nullable: true},
        skills: %Schema{type: :array, items: %Schema{type: :string}},
        workAreas: %Schema{type: :array, items: %Schema{type: :string}}
      },
      required: [
        :id,
        :userId,
        :name,
        :email,
        :phone,
        :currentStep,
        :createdAt,
        :updatedAt,
        :lastSavedAt,
        :city,
        :bio,
        :hoursPerWeek,
        :skills,
        :workAreas
      ]
    })
  end

  defmodule AdminCleanerApplicationDraftListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.AdminCleanerApplicationDraft
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerApplicationDraftListResponse",
      type: :object,
      properties: %{drafts: %Schema{type: :array, items: AdminCleanerApplicationDraft}},
      required: [:drafts]
    })
  end

  defmodule AdminCleanerHealthKpis do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthKpis",
      type: :object,
      properties: %{
        openCases: %Schema{type: :integer},
        redRiskCleaners: %Schema{type: :integer},
        yellowRiskCleaners: %Schema{type: :integer},
        averageCleanerRating: %Schema{type: :number, nullable: true},
        noShowsThisMonth: %Schema{type: :integer},
        complaintsThisMonth: %Schema{type: :integer}
      },
      required: [
        :openCases,
        :redRiskCleaners,
        :yellowRiskCleaners,
        :averageCleanerRating,
        :noShowsThisMonth,
        :complaintsThisMonth
      ]
    })
  end

  defmodule AdminCleanerHealthCase do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthCase",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        cleanerId: %Schema{type: :string, format: :uuid},
        cleanerName: %Schema{type: :string},
        severity: %Schema{type: :string, enum: ["yellow", "red"]},
        riskScore: %Schema{type: :integer},
        mainReason: %Schema{type: :string},
        rating: %Schema{type: :number, nullable: true},
        recentJobs: %Schema{type: :integer},
        assignedToName: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :cleanerId,
        :cleanerName,
        :severity,
        :riskScore,
        :mainReason,
        :rating,
        :recentJobs,
        :assignedToName,
        :status,
        :createdAt
      ]
    })
  end

  defmodule AdminCleanerHealthRiskReason do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthRiskReason",
      type: :object,
      properties: %{
        label: %Schema{type: :string},
        points: %Schema{type: :integer}
      },
      required: [:label, :points]
    })
  end

  defmodule AdminCleanerHealthCaseAction do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthCaseAction",
      type: :object,
      properties: %{
        actionType: %Schema{type: :string},
        notes: %Schema{type: :string, nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:actionType, :notes, :createdAt]
    })
  end

  defmodule AdminCleanerHealthPreviousCase do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthPreviousCase",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string},
        status: %Schema{type: :string},
        severity: %Schema{type: :string, enum: ["yellow", "red"]},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :title, :status, :severity, :createdAt]
    })
  end

  defmodule AdminCleanerHealthCaseDetail do
    require OpenApiSpex

    alias MithrilWeb.Schemas.Direct.{
      AdminCleanerHealthCaseAction,
      AdminCleanerHealthPreviousCase,
      AdminCleanerHealthRiskReason
    }

    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthCaseDetail",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        cleanerId: %Schema{type: :string, format: :uuid},
        cleanerName: %Schema{type: :string},
        severity: %Schema{type: :string, enum: ["yellow", "red"]},
        riskScore: %Schema{type: :integer},
        riskLevel: %Schema{type: :string, nullable: true},
        mainReason: %Schema{type: :string},
        rating: %Schema{type: :number, nullable: true},
        recentJobs: %Schema{type: :integer},
        assignedToName: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"},
        aiSummary: %Schema{type: :string, nullable: true},
        aiRecommendation: %Schema{type: :string, nullable: true},
        aiCategories: %Schema{type: :array, items: %Schema{type: :string}},
        resolutionNotes: %Schema{type: :string, nullable: true},
        evidenceJson: %Schema{type: :string, nullable: true},
        riskReasons: %Schema{type: :array, items: AdminCleanerHealthRiskReason},
        reviewComments: %Schema{type: :array, items: %Schema{type: :string}},
        actions: %Schema{type: :array, items: AdminCleanerHealthCaseAction},
        previousCases: %Schema{type: :array, items: AdminCleanerHealthPreviousCase}
      },
      required: [
        :id,
        :cleanerId,
        :cleanerName,
        :severity,
        :riskScore,
        :riskLevel,
        :mainReason,
        :rating,
        :recentJobs,
        :assignedToName,
        :status,
        :createdAt,
        :aiSummary,
        :aiRecommendation,
        :aiCategories,
        :resolutionNotes,
        :evidenceJson,
        :riskReasons,
        :reviewComments,
        :actions,
        :previousCases
      ]
    })
  end

  defmodule AdminCleanerHealthActionRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthActionRequest",
      type: :object,
      properties: %{
        actionType: %Schema{
          type: :string,
          enum: ~w(monitor coaching training warning investigation resolved dismissed)
        },
        notes: %Schema{type: :string, nullable: true}
      },
      required: [:actionType]
    })
  end

  defmodule AdminCleanerHealthListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.{AdminCleanerHealthCase, AdminCleanerHealthKpis}
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCleanerHealthListResponse",
      type: :object,
      properties: %{
        kpis: AdminCleanerHealthKpis,
        cases: %Schema{type: :array, items: AdminCleanerHealthCase}
      },
      required: [:kpis, :cases]
    })
  end

  defmodule AdminCustomerTrustProfile do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustProfile",
      type: :object,
      properties: %{
        customerId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        verificationStage: %Schema{type: :string, nullable: true},
        verificationRequired: %Schema{type: :boolean},
        idVerified: %Schema{type: :boolean},
        phoneVerified: %Schema{type: :boolean},
        canProceedToPayment: %Schema{type: :boolean},
        canDispatchCleaner: %Schema{type: :boolean},
        riskScore: %Schema{type: :integer},
        failedPaymentCount: %Schema{type: :integer},
        chargebackCount: %Schema{type: :integer},
        cleanerComplaintCount: %Schema{type: :integer},
        completedBookingsCount: %Schema{type: :integer},
        lastRiskEventAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [
        :customerId,
        :name,
        :email,
        :phone,
        :verificationStage,
        :verificationRequired,
        :idVerified,
        :phoneVerified,
        :canProceedToPayment,
        :canDispatchCleaner,
        :riskScore,
        :failedPaymentCount,
        :chargebackCount,
        :cleanerComplaintCount,
        :completedBookingsCount,
        :lastRiskEventAt
      ]
    })
  end

  defmodule AdminCustomerTrustRiskEvent do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustRiskEvent",
      type: :object,
      properties: %{
        eventType: %Schema{type: :string},
        severity: %Schema{type: :integer},
        createdAt: %Schema{type: :string, format: :"date-time"},
        voided: %Schema{type: :boolean},
        bookingId: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:eventType, :severity, :createdAt, :voided, :bookingId]
    })
  end

  defmodule AdminCustomerTrustBooking do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustBooking",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        scheduledDate: %Schema{type: :string, nullable: true},
        scheduledTime: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, nullable: true},
        paymentStatus: %Schema{type: :string, nullable: true},
        finalAmountMinor: %Schema{type: :integer, nullable: true},
        title: %Schema{type: :string, nullable: true},
        address: %Schema{type: :string, nullable: true}
      },
      required: [
        :id,
        :scheduledDate,
        :scheduledTime,
        :status,
        :paymentStatus,
        :finalAmountMinor,
        :title,
        :address
      ]
    })
  end

  defmodule AdminCustomerTrustNote do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustNote",
      type: :object,
      properties: %{
        note: %Schema{type: :string},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:note, :createdAt]
    })
  end

  defmodule AdminCustomerTrustAdminAction do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustAdminAction",
      type: :object,
      properties: %{
        actionType: %Schema{type: :string},
        reason: %Schema{type: :string, nullable: true},
        createdAt: %Schema{type: :string, format: :"date-time"}
      },
      required: [:actionType, :reason, :createdAt]
    })
  end

  defmodule AdminCustomerTrustDetail do
    require OpenApiSpex

    alias MithrilWeb.Schemas.Direct.{
      AdminCustomerTrustAdminAction,
      AdminCustomerTrustBooking,
      AdminCustomerTrustNote,
      AdminCustomerTrustRiskEvent
    }

    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustDetail",
      type: :object,
      properties: %{
        customerId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        email: %Schema{type: :string, nullable: true},
        phone: %Schema{type: :string, nullable: true},
        verificationStage: %Schema{type: :string, nullable: true},
        verificationRequired: %Schema{type: :boolean},
        verificationReason: %Schema{type: :string, nullable: true},
        idVerified: %Schema{type: :boolean},
        phoneVerified: %Schema{type: :boolean},
        canProceedToPayment: %Schema{type: :boolean},
        canDispatchCleaner: %Schema{type: :boolean},
        riskScore: %Schema{type: :integer},
        failedPaymentCount: %Schema{type: :integer},
        chargebackCount: %Schema{type: :integer},
        cleanerComplaintCount: %Schema{type: :integer},
        completedBookingsCount: %Schema{type: :integer},
        lastRiskEventAt: %Schema{type: :string, format: :"date-time", nullable: true},
        lastReviewedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        adminOverrideStage: %Schema{type: :string, nullable: true},
        adminOverrideReason: %Schema{type: :string, nullable: true},
        adminExplanation: %Schema{type: :string},
        kycStatus: %Schema{type: :string, nullable: true},
        kycReviewAnswer: %Schema{type: :string, nullable: true},
        kycUpdatedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        riskEvents: %Schema{type: :array, items: AdminCustomerTrustRiskEvent},
        bookings: %Schema{type: :array, items: AdminCustomerTrustBooking},
        adminNotes: %Schema{type: :array, items: AdminCustomerTrustNote},
        adminActions: %Schema{type: :array, items: AdminCustomerTrustAdminAction}
      },
      required: [
        :customerId,
        :name,
        :email,
        :phone,
        :verificationStage,
        :verificationRequired,
        :verificationReason,
        :idVerified,
        :phoneVerified,
        :canProceedToPayment,
        :canDispatchCleaner,
        :riskScore,
        :failedPaymentCount,
        :chargebackCount,
        :cleanerComplaintCount,
        :completedBookingsCount,
        :lastRiskEventAt,
        :lastReviewedAt,
        :adminOverrideStage,
        :adminOverrideReason,
        :adminExplanation,
        :kycStatus,
        :kycReviewAnswer,
        :kycUpdatedAt,
        :riskEvents,
        :bookings,
        :adminNotes,
        :adminActions
      ]
    })
  end

  defmodule AdminCustomerTrustNoteRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustNoteRequest",
      type: :object,
      properties: %{
        note: %Schema{type: :string}
      },
      required: [:note]
    })
  end

  defmodule AdminCustomerTrustActionRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustActionRequest",
      type: :object,
      properties: %{
        action: %Schema{
          type: :string,
          enum: ~w(
            mark_reviewed
            clear_manual_review
            require_manual_review
            require_id_before_payment
            require_id_before_dispatch
          )
        },
        reason: %Schema{type: :string}
      },
      required: [:action, :reason]
    })
  end

  defmodule AdminOpsMutationResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminOpsMutationResponse",
      type: :object,
      properties: %{
        message: %Schema{type: :string}
      },
      required: [:message]
    })
  end

  defmodule AdminCustomerTrustListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.Direct.AdminCustomerTrustProfile
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminCustomerTrustListResponse",
      type: :object,
      properties: %{profiles: %Schema{type: :array, items: AdminCustomerTrustProfile}},
      required: [:profiles]
    })
  end
end
