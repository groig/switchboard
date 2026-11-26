defmodule SwitchboardWeb.Dev.FakeForgejo do
  @moduledoc """
  A tiny Forgejo stand-in for local development and the spike: an OAuth2 provider (with PKCE)
  plus `/api/v1/user`, `/api/v1/user/orgs` and `/api/v1/user/teams`, with refresh tokens. It approves every login as the configured
  identity (`:switchboard, SwitchboardWeb.Dev.FakeForgejo, user: %{...}`). Mounted only with
  `dev_routes`, never in production.
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason
  plug :dispatch

  @salt "fake-forgejo"

  get "/login/oauth/authorize" do
    p = conn.query_params

    code =
      Phoenix.Token.sign(SwitchboardWeb.Endpoint, @salt, %{
        challenge: p["code_challenge"],
        redirect_uri: p["redirect_uri"]
      })

    query = URI.encode_query(%{"code" => code, "state" => p["state"]})
    conn |> put_resp_header("location", p["redirect_uri"] <> "?" <> query) |> send_resp(302, "")
  end

  post "/login/oauth/access_token" do
    p = conn.body_params

    with {:ok, %{challenge: challenge, redirect_uri: uri}} <-
           Phoenix.Token.verify(SwitchboardWeb.Endpoint, @salt, p["code"], max_age: 60),
         true <- uri == p["redirect_uri"],
         true <-
           Base.url_encode64(:crypto.hash(:sha256, p["code_verifier"] || ""), padding: false) ==
             challenge do
      json(conn, 200, token_response())
    else
      _ -> refresh(conn, p)
    end
  end

  defp refresh(conn, %{"grant_type" => "refresh_token", "refresh_token" => "fake-forgejo-refresh"}),
       do: json(conn, 200, token_response())

  defp refresh(conn, _), do: json(conn, 400, %{error: "invalid_grant"})

  defp token_response do
    %{
      access_token: "fake-forgejo-token",
      refresh_token: "fake-forgejo-refresh",
      token_type: "bearer",
      expires_in: 3600
    }
  end

  get "/api/v1/user" do
    if authorized?(conn),
      do: json(conn, 200, user()),
      else: json(conn, 401, %{message: "unauthorized"})
  end

  get "/api/v1/user/orgs" do
    if authorized?(conn),
      do: json(conn, 200, [%{id: 1, username: "Acme"}]),
      else: json(conn, 401, %{message: "unauthorized"})
  end

  get "/api/v1/user/teams" do
    if authorized?(conn),
      do: json(conn, 200, [%{id: 1, name: "Developers", organization: %{username: "Acme"}}]),
      else: json(conn, 401, %{message: "unauthorized"})
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp authorized?(conn),
    do: get_req_header(conn, "authorization") == ["Bearer fake-forgejo-token"]

  defp user do
    Map.merge(
      %{id: 1, login: "dev", full_name: "Dev User", email: "dev@example.com", active: true},
      Application.get_env(:switchboard, __MODULE__, [])[:user] || %{}
    )
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
