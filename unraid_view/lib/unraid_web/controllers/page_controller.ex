defmodule UnraidWeb.PageController do
  use UnraidWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
