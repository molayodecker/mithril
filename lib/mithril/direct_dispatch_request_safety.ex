defmodule Mithril.DirectDispatchRequestSafety do
  @moduledoc "Server-side validation for customer-created Direct dispatch requests."

  alias Mithril.DirectDispatch

  def create_urgent_request(user_id, params) when is_map(params) do
    DirectDispatch.create_urgent_request(user_id, params)
  end
end
