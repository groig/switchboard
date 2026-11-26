defmodule SwitchboardWeb.ErrorMessages do
  @moduledoc """
  Changeset messages written in our schemas. Listed here with `dgettext_noop/2` so
  `mix gettext.extract` puts them in the "errors" domain;
  `SwitchboardWeb.CoreComponents.translate_error/1` translates them at render time.
  """
  use Gettext, backend: SwitchboardWeb.Gettext

  @doc false
  def messages do
    [
      dgettext_noop("errors", "is not a valid time zone")
    ]
  end
end
