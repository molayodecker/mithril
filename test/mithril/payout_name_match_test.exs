defmodule Mithril.PayoutNameMatchTest do
  use ExUnit.Case, async: true

  alias Mithril.PayoutNameMatch

  test "the same person matches with different order, case, and punctuation" do
    assert PayoutNameMatch.names_match?("Ama Serwaa", "SERWAA AMA")
    assert PayoutNameMatch.names_match?("José Mensah", "Jose Mensah")
    assert PayoutNameMatch.names_match?("Jane Doe", "Doe Jane")
  end

  test "a different person does not match" do
    assert PayoutNameMatch.names_mismatch?("Ama Serwaa", "MENSAH-BOATENG")
    refute PayoutNameMatch.names_match?("AMA MENSAH-BOATENG", "ama mensahboateng")
  end

  test "a blank name is not treated as a mismatch" do
    assert PayoutNameMatch.names_match?("", "AMA MENSAH")
    assert PayoutNameMatch.names_match?(nil, "AMA MENSAH")
  end
end
