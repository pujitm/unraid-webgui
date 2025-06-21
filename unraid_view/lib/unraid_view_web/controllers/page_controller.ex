defmodule UnraidViewWeb.PageController do
  use UnraidViewWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
