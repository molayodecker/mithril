defmodule MithrilWeb.MobileCallRouter do
  @moduledoc """
  Registers one static path per allowlisted RPC and mobile function.

  Table queries stay on `POST /mobile/query` until each read or write has its own
  resource route. The old `/mobile/rpc/:name` and `/mobile/functions/*name`
  routes stay so callers can move one at a time.
  """

  alias Mithril.MobileGateway
  alias Mithril.MobileRpc

  defmacro user_routes do
    routes =
      rpc_routes(MobileRpc.names(), "/calls/", :user_rpc) ++
        action_routes(MobileGateway.function_names(), "/actions/", :user_action)

    quote do
      (unquote_splicing(routes))
    end
  end

  defmacro guest_routes do
    routes =
      rpc_routes(MobileGateway.guest_rpc_names(), "/guest/calls/", :guest_rpc) ++
        action_routes(MobileGateway.guest_function_names(), "/guest/actions/", :guest_action)

    quote do
      (unquote_splicing(routes))
    end
  end

  defp rpc_routes(names, prefix, kind) do
    for name <- names do
      quote do
        post unquote(prefix <> String.replace(name, "_", "-")),
             MithrilWeb.Plugs.MobileCall,
             unquote({kind, name}),
             alias: false
      end
    end
  end

  defp action_routes(names, prefix, kind) do
    for name <- names do
      quote do
        post unquote(prefix <> name),
             MithrilWeb.Plugs.MobileCall,
             unquote({kind, name}),
             alias: false
      end
    end
  end
end
