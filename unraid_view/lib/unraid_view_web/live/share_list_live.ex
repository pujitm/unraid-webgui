defmodule UnraidViewWeb.ShareListLive do
  @moduledoc """
  LiveView card that shows all user shares found in Unraid's `state/shares.ini` file.

  The component watches that file by polling its modification time every few
  seconds.  When the mtime changes the shares are re-parsed and the view is
  updated.
  """
  use Phoenix.LiveView

  @shares_ini System.get_env("UNRAID_SHARES_INI", "/usr/local/emhttp/state/shares.ini")
  @poll_interval 5_000

  # -------------------------------------------------------------------------
  # Mount / polling loop
  # -------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    shares = load_shares()
    mtime = file_mtime()

    if connected?(socket), do: :timer.send_interval(@poll_interval, :poll)

    {:ok, assign(socket, shares: shares, mtime: mtime)}
  end

  @impl true
  def handle_info(:poll, socket) do
    current_mtime = socket.assigns.mtime

    case file_mtime() do
      ^current_mtime ->
        {:noreply, socket}

      new_mtime ->
        {:noreply, assign(socket, shares: load_shares(), mtime: new_mtime)}
    end
  end

  # -------------------------------------------------------------------------
  # Rendering
  # -------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl card-border border-primary">
      <div class="card-body">
        <h2 class="card-title text-sm">Shares (Unraid)</h2>
        <%= if @shares == [] do %>
          <p class="text-sm opacity-60">No shares found</p>
        <% else %>
          <ul class="divide-y divide-base-300">
            <%= for %{name: name, comment: comment} <- @shares do %>
              <li class="flex flex-col py-1 sm:flex-row sm:items-center sm:justify-between">
                <span class="font-medium">{name}</span>
                <%= if comment != "" do %>
                  <span class="text-xs opacity-80">{comment}</span>
                <% end %>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  # Returns list of `%{name: String.t(), comment: String.t()}` maps by parsing
  # the shares.ini file with the Erlang `:eini` library (declared in mix.exs).
  defp load_shares do
    with {:ok, contents} <- File.read(@shares_ini),
         {:ok, props} <- parse_ini(contents) do
      Enum.map(props, fn {section, kv} ->
        kv_map = Enum.into(kv, %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
        %{name: to_string(section), comment: Map.get(kv_map, "comment", "")}
      end)
    else
      _ -> []
    end
  end

  defp file_mtime do
    case File.stat(@shares_ini) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  # Attempt to parse with :eini; if it fails because section names are quoted
  # (Unraid uses the non-standard ["section"] syntax), strip the quotes and
  # try again.
  defp parse_ini(contents) do
    case :eini.parse(String.to_charlist(contents)) do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        contents
        |> String.replace(~r/\[\"([^\"]+)\"\]/, "[\\1]")
        |> String.to_charlist()
        |> :eini.parse()
    end
  end
end
