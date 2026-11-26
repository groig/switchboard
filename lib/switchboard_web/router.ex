defmodule SwitchboardWeb.Router do
  use SwitchboardWeb, :router

  import SwitchboardWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SwitchboardWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "referrer-policy" => "strict-origin-when-cross-origin",
      "x-robots-tag" => "noindex, nofollow",
      "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    }

    plug SwitchboardWeb.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope
    plug SwitchboardWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # OAuth endpoints called by MCP clients (no cookies, no CSRF).
  pipeline :oauth_client do
    plug :accepts, ["json", "html"]
  end

  pipeline :mcp do
    plug SwitchboardWeb.Plugs.MCPAuth
  end

  scope "/.well-known", SwitchboardWeb do
    pipe_through :api

    get "/oauth-authorization-server", OAuthController, :authorization_server_metadata
    get "/oauth-protected-resource", OAuthController, :protected_resource_metadata
    get "/oauth-protected-resource/mcp", OAuthController, :protected_resource_metadata
  end

  scope "/oauth", SwitchboardWeb do
    pipe_through :oauth_client

    post "/register", OAuthController, :register
    post "/token", OAuthController, :token
    post "/revoke", OAuthController, :revoke
  end

  scope "/", SwitchboardWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/oauth/authorize", OAuthController, :authorize
    post "/oauth/authorize", OAuthController, :decide
    get "/auth/forgejo", AuthController, :login
    get "/auth/forgejo/callback", AuthController, :callback
    delete "/auth/logout", AuthController, :logout
  end

  ## The web app (signed in)

  scope "/", SwitchboardWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :app,
      on_mount: [
        {SwitchboardWeb.UserAuth, :require_authenticated},
        SwitchboardWeb.Locale,
        SwitchboardWeb.Shell
      ] do
      live "/connections", ConnectionsLive, :index
      live "/clients", ClientsLive, :index
      live "/activity", ActivityLive, :index
      live "/watches", WatchesLive, :index
      live "/profile", ProfileLive, :index
    end
  end

  ## Admin (private network only at the proxy; ADMIN_NETWORKS in the app as well)

  scope "/admin", SwitchboardWeb.Admin do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    live_session :admin,
      on_mount: [
        SwitchboardWeb.AdminNetwork,
        {SwitchboardWeb.UserAuth, :require_admin},
        SwitchboardWeb.Locale,
        SwitchboardWeb.Shell
      ] do
      live "/", ControlsLive, :index
      live "/audit", AuditLive, :index
      live "/people", PeopleLive, :index
      live "/health", HealthLive, :index
    end
  end

  scope "/" do
    pipe_through :mcp

    forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: Switchboard.MCP.Server
  end

  if Application.compile_env(:switchboard, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SwitchboardWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/dev" do
      pipe_through [:browser, :require_authenticated_user]

      live_session :dev,
        on_mount: [
          {SwitchboardWeb.UserAuth, :require_authenticated},
          SwitchboardWeb.Locale,
          SwitchboardWeb.Shell
        ] do
        live "/design", SwitchboardWeb.Dev.DesignLive, :index
      end
    end

    scope "/dev" do
      forward "/fake_forgejo", SwitchboardWeb.Dev.FakeForgejo
    end
  end
end
