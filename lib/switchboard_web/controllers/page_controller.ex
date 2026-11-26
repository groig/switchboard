defmodule SwitchboardWeb.PageController do
  use SwitchboardWeb, :controller

  def home(conn, _params) do
    if scope = conn.assigns.current_scope do
      redirect(conn, to: SwitchboardWeb.UserAuth.signed_in_path(scope.user))
    else
      render(conn, :home, mcp_url: Switchboard.OAuth.resource(), page_title: gettext("Sign in"))
    end
  end
end
