defmodule UnraidViewWeb.VmStatusLive do
  @moduledoc """
  LiveView card that lists all virtual machines available on the host together
  with their current status (e.g. *running*, *shut off*).

  The component polls `virsh list --all` every few seconds (when the LiveView is
  connected) to keep the list up-to-date.
  """
  use Phoenix.LiveView

  @refresh_interval 5_000

  # ---------------------------------------------------------------------------
  # Mount / periodic refresh
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_interval, :refresh)

    {:ok, assign(socket, vms: fetch_vms())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :vms, fetch_vms())}
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl card-border border-primary">
      <div class="card-body">
        <h2 class="card-title text-sm">Virtual Machines</h2>
        <%= if @vms == [] do %>
          <p class="text-sm opacity-60">No VMs found</p>
        <% else %>
          <ul class="divide-y divide-base-300">
            <%= for {name, status} <- @vms do %>
              <li class="flex items-center justify-between py-1">
                <span class="font-medium"><%= name %></span>
                <span class={["badge badge-sm", badge_class(status)]}>
                  <%= status %>
                </span>
              </li>
            <% end %>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Executes `virsh list --all` and parses the output into a list of `{name, status}` tuples.
  # If the command fails (for instance when libvirt is not installed), an empty list is returned.
  defp fetch_vms do
    case System.cmd("virsh", ["list", "--all"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.drop(2) # skip header lines
        |> Enum.filter(&(String.trim(&1) != ""))
        |> Enum.map(&parse_line/1)

      _ ->
        []
    end
  end

  # Parses a single line of `virsh list --all` output.
  # Example line formats:
  #   " 1     ubuntu                         running"
  #   " -     win10                          shut off"
  defp parse_line(line) do
    tokens = String.split(line, ~r/\s+/, trim: true)

    case tokens do
      [_id, name | status_tokens] -> {name, Enum.join(status_tokens, " ")}
      _ -> {line, "unknown"}
    end
  end

  defp badge_class(status) do
    cond do
      String.contains?(status, "running") -> "badge-success"
      true -> "badge-ghost"
    end
  end
end
