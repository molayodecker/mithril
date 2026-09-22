defmodule MithrilWeb.Schemas.DirectAdminLiveJobs do
  @moduledoc "OpenAPI schemas for the Direct admin live jobs board."

  defmodule Milestone do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminLiveJobMilestone",
      type: :object,
      properties: %{
        stage: %Schema{type: :string},
        changedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:stage]
    })
  end

  defmodule Tracking do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminLiveJobTracking",
      type: :object,
      nullable: true,
      properties: %{
        latitude: %Schema{type: :number},
        longitude: %Schema{type: :number},
        heading: %Schema{type: :number, nullable: true},
        accuracy: %Schema{type: :number, nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:latitude, :longitude]
    })
  end

  defmodule Photos do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminLiveJobPhotos",
      type: :object,
      properties: %{
        before: %Schema{type: :integer, minimum: 0},
        during: %Schema{type: :integer, minimum: 0},
        after: %Schema{type: :integer, minimum: 0},
        issue: %Schema{type: :integer, minimum: 0},
        total: %Schema{type: :integer, minimum: 0}
      },
      required: [:before, :during, :after, :issue, :total]
    })
  end

  defmodule Job do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminLiveJobs.{Milestone, Photos, Tracking}
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminLiveJob",
      type: :object,
      properties: %{
        bookingId: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string},
        serviceName: %Schema{type: :string},
        scheduledDate: %Schema{type: :string, format: :date, nullable: true},
        scheduledTime: %Schema{type: :string, nullable: true},
        durationHours: %Schema{type: :number, nullable: true},
        timezone: %Schema{type: :string},
        address: %Schema{type: :string, nullable: true},
        latitude: %Schema{type: :number, nullable: true},
        longitude: %Schema{type: :number, nullable: true},
        customerName: %Schema{type: :string},
        customerPhone: %Schema{type: :string, nullable: true},
        cleanerId: %Schema{type: :string, format: :uuid},
        cleanerName: %Schema{type: :string},
        cleanerPhone: %Schema{type: :string, nullable: true},
        updatedAt: %Schema{type: :string, format: :"date-time", nullable: true},
        milestones: %Schema{type: :array, items: Milestone},
        tracking: Tracking,
        photos: Photos
      },
      required: [
        :bookingId,
        :status,
        :serviceName,
        :timezone,
        :customerName,
        :cleanerId,
        :cleanerName,
        :milestones,
        :photos
      ]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias MithrilWeb.Schemas.DirectAdminLiveJobs.Job
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminLiveJobsResponse",
      type: :object,
      properties: %{
        generatedAt: %Schema{type: :string, format: :"date-time"},
        jobs: %Schema{type: :array, items: Job}
      },
      required: [:generatedAt, :jobs]
    })
  end
end
