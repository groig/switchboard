defmodule SwitchboardWeb.PageController do
  use SwitchboardWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/connections")
    else
      render(conn, :home, mcp_url: Switchboard.OAuth.resource(), page_title: gettext("Sign in"))
    end
  end
end
