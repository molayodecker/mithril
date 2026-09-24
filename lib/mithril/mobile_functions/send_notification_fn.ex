defmodule Mithril.MobileFunctions.SendNotificationFn do
  @moduledoc false

  alias Mithril.Notifications.SendNotification

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(_user_id, body) when is_map(body), do: SendNotification.invoke_mobile(body)
end
