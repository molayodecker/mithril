defmodule MithrilWeb.Schemas.DirectAdminWallet do
  @moduledoc "OpenAPI schemas for worker wallet reads and credits."

  defmodule Wallet do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWorkerWallet",
      type: :object,
      properties: %{
        balanceMinor: %Schema{type: :integer, nullable: true},
        currency: %Schema{type: :string}
      },
      required: [:currency]
    })
  end

  defmodule CreditRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWalletCreditRequest",
      type: :object,
      properties: %{
        amountMinor: %Schema{type: :integer, minimum: 1},
        notes: %Schema{type: :string, maxLength: 500, nullable: true}
      },
      required: [:amountMinor]
    })
  end

  defmodule CreditResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DirectAdminWalletCreditResponse",
      type: :object,
      properties: %{
        amountMinor: %Schema{type: :integer},
        newBalanceMinor: %Schema{type: :integer, nullable: true},
        currency: %Schema{type: :string}
      },
      required: [:amountMinor, :currency]
    })
  end
end
