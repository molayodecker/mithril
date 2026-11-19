defmodule Mithril.DirectContracts.WorkerRatingTest do
  use ExUnit.Case, async: true

  alias Mithril.DirectContracts.WorkerRating
  alias Mithril.WhatsApp.ContractWorkerRatingTemplate

  test "the first rating is due three months after the contract starts" do
    start_on = ~D[2026-01-15]
    assert WorkerRating.due?(start_on, nil, ~D[2026-04-15])
    refute WorkerRating.due?(start_on, nil, ~D[2026-04-14])
  end

  test "the next rating is due three months after the last send" do
    start_on = ~D[2025-01-01]
    last_sent = ~U[2026-01-15 08:00:00Z]
    assert WorkerRating.due?(start_on, last_sent, ~D[2026-04-15])
    refute WorkerRating.due?(start_on, last_sent, ~D[2026-04-14])
  end

  test "the greeting and worker label stay on one line" do
    assert WorkerRating.greeting("Ama\n{Owusu}") == "Ama"
    assert WorkerRating.greeting("  ") == "there"
    assert WorkerRating.worker_label(["Efua Mensah"]) == "Efua Mensah"
    assert WorkerRating.worker_label(["Efua Mensah", "Kojo"]) == "your team"
  end

  test "the WhatsApp template names the client and worker and links to the rating page" do
    assert ContractWorkerRatingTemplate.body() =~ "Hello {{1}}"
    assert ContractWorkerRatingTemplate.body() =~ "how is {{2}} doing?"

    action =
      hd(ContractWorkerRatingTemplate.definition()["types"]["twilio/call-to-action"]["actions"])

    assert action["title"] == "Rate your worker"
    assert action["url"] == "#{ContractWorkerRatingTemplate.public_base()}/rate/{{3}}"

    message =
      ContractWorkerRatingTemplate.readable(
        "Ama",
        "Efua",
        "#{ContractWorkerRatingTemplate.public_base()}/rate/#{"ab" |> String.duplicate(32)}"
      )

    assert message =~ "Hello Ama, how is Efua doing?"
    assert message =~ "/rate/"
  end
end
