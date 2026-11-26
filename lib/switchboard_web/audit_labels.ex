defmodule SwitchboardWeb.AuditLabels do
  @moduledoc "Human labels for audit actions and outcomes, in the reader's language."
  use Gettext, backend: SwitchboardWeb.Gettext

  @doc "A short label for a web action; tool calls show the tool name."
  def action("login"), do: gettext("Signed in")
  def action("logout"), do: gettext("Signed out")
  def action("profile.updated"), do: gettext("Changed profile")
  def action("connection.linked"), do: gettext("Linked a key")
  def action("connection.unlinked"), do: gettext("Removed a key")
  def action("connection.tested"), do: gettext("Tested a key")
  def action("personal_token.created"), do: gettext("Created a personal token")
  def action("personal_token.revoked"), do: gettext("Revoked a personal token")
  def action("client.revoked"), do: gettext("Disconnected a client")
  def action("oauth.approved"), do: gettext("Approved a client")
  def action("oauth.denied"), do: gettext("Denied a client")
  def action("watch.cancelled"), do: gettext("Cancelled a watch")
  def action("admin.controls_updated"), do: gettext("Changed global controls")
  def action("admin.tool_updated"), do: gettext("Changed a tool's controls")
  def action("admin.tool_reset"), do: gettext("Reset a tool's controls")
  def action("admin.revoke_all"), do: gettext("Revoked everything for a person")
  def action(other), do: other

  def outcome("ok"), do: gettext("OK")
  def outcome("error"), do: gettext("Error")
  def outcome("denied"), do: gettext("Denied")
  def outcome("rate_limited"), do: gettext("Rate limited")
  def outcome("disabled"), do: gettext("Disabled")
  def outcome(other), do: other

  def kind("mcp"), do: gettext("Tool call")
  def kind("web"), do: gettext("Web")
  def kind(other), do: other
end
