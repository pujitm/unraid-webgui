defmodule UnraidWeb.Router do
  use UnraidWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UnraidWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", UnraidWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/event-demo", EventDemoLive
  end

  scope "/", UnraidWeb do
    pipe_through :browser

    live_session :dashboard, layout: {UnraidWeb.Layouts, :wide} do
      live "/docker", DockerCardDemoLive
      live "/docker/table", DockerLive
      live "/docker/card", DockerCardDemoLive
      live "/docker/add", DockerAddLive
      live "/docker/:name/edit", DockerEditLive
      live "/terminal", TerminalLive
      live "/terminal/sessions/:session_id", TerminalSessionLive
      live "/vms", VmLive
      live "/events", EventLogLive
      live "/log_monitor_demo", LogMonitorDemoLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", UnraidWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:unraid, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: UnraidWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
