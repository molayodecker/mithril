defmodule MithrilWeb.Schemas.DirectContractWorkerRating do
  @moduledoc false

  alias OpenApiSpex.Schema

  defmodule AdminRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DirectAdminContractWorkerRatingRequest",
      type: :object,
      properties: %{
        phone: %Schema{
          type: :string,
          nullable: true,
          description:
            "Ghana number for this message. Blank uses the number saved on the contract."
        }
      }
    })
  end

  defmodule AdminResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DirectAdminContractWorkerRatingResult",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        sent: %Schema{type: :boolean},
        phone: %Schema{type: :string}
      },
      required: [:ok, :sent, :phone]
    })
  end

  defmodule Worker do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DirectContractWorkerRatingWorker",
      type: :object,
      properties: %{
        workerId: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        rating: %Schema{type: :integer, minimum: 1, maximum: 5, nullable: true},
        comment: %Schema{type: :string, nullable: true}
      },
      required: [:workerId, :name, :rating, :comment]
    })
  end

  defmodule Public do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DirectContractWorkerRating",
      type: :object,
      properties: %{
        clientName: %Schema{type: :string},
        complete: %Schema{type: :boolean},
        workers: %Schema{type: :array, items: Worker}
      },
      required: [:clientName, :complete, :workers]
    })
  end

  defmodule RatingInput do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DirectContractWorkerRatingInput",
      type: :object,
      properties: %{
        workerId: %Schema{type: :string, format: :uuid},
        rating: %Schema{type: :integer, minimum: 1, maximum: 5},
        comment: %Schema{type: :string, nullable: true, maxLength: 500}
      },
      required: [:workerId, :rating]
    })
  end

  defmodule SubmitRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "DirectContractWorkerRatingSubmitRequest",
      type: :object,
      properties: %{
        ratings: %Schema{type: :array, minItems: 1, maxItems: 20, items: RatingInput}
      },
      required: [:ratings]
    })
  end
end
