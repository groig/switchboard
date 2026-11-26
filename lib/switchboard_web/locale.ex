defmodule SwitchboardWeb.Locale do
  @moduledoc """
  Resolves the UI locale, as a plug (plain requests) and as a LiveView `on_mount` hook:

    1. the signed-in person's profile setting (`es` or `en`);
    2. otherwise the browser's `Accept-Language`;
    3. otherwise Spanish, the company default.

  Dates use the profile's time zone (`SwitchboardWeb.Format`); everything is stored in UTC.
  """

  import Plug.Conn

  alias Switchboard.Accounts.User
  alias Switchboard.Scope

  @supported ~w(es en)
  @default "es"

  def supported, do: @supported

  ## Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    browser_locale = conn |> get_req_header("accept-language") |> List.first() |> from_header()
    locale = resolve(current_user(conn.assigns[:current_scope]), browser_locale)
    Gettext.put_locale(SwitchboardWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_session(:browser_locale, browser_locale)
  end

  ## LiveView

  def on_mount(:default, _params, session, socket) do
    locale = resolve(current_user(socket.assigns[:current_scope]), session["browser_locale"])
    Gettext.put_locale(SwitchboardWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  defp current_user(%Scope{user: %User{} = user}), do: user
  defp current_user(_), do: nil

  ## Resolution

  @doc "Picks the locale from a user preference and a browser locale."
  def resolve(%User{locale: locale}, _browser) when locale in @supported, do: locale
  def resolve(_user, browser) when browser in @supported, do: browser
  def resolve(_user, _browser), do: @default

  @doc """
  Returns the best supported locale from an `Accept-Language` header, or nil.

      iex> SwitchboardWeb.Locale.from_header("en-GB,en;q=0.9,es;q=0.8")
      "en"
  """
  def from_header(nil), do: nil

  def from_header(header) when is_binary(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.map(&parse_language_range/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_lang, q} -> q end, :desc)
    |> Enum.find_value(fn {lang, _q} -> if lang in @supported, do: lang end)
  end

  defp parse_language_range(range) do
    [tag | params] = range |> String.trim() |> String.split(";")
    lang = tag |> String.split("-") |> hd() |> String.downcase()

    q =
      Enum.find_value(params, 1.0, fn param ->
        case String.split(String.trim(param), "=") do
          ["q", value] -> parse_q(value)
          _ -> nil
        end
      end)

    if lang != "" and q > 0, do: {lang, q}
  end

  defp parse_q(value) do
    case Float.parse(value) do
      {q, _} -> q
      :error -> 0.0
    end
  end
end
