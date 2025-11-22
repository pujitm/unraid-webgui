# UnraidView

A Phoenix LiveView application for monitoring and managing Unraid systems.

## Demo Setup

For live demonstrations, this app is pre-configured to work with the following hosts:
- `zima.local`
- `hanzo.local`

### Quick Demo Start

```bash
# Run the demo (production mode)
./run_demo.sh
```

The app will be available at:
- http://zima.local:4000
- http://hanzo.local:4000
- http://localhost:4000

### Development Mode

```bash
# Run in development mode
./run_dev.sh
```

## Production Release

For production deployment, you can create a standalone release that doesn't require Mix or Elixir on the target system:

### Build Release

```bash
# Build a production release
./build_release.sh
```

### Run Release

```bash
# Run the built release
./run_release.sh
```

### Manual Release Commands

```bash
# Build release manually
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release

# Run release directly
_build/prod/rel/unraid_view/bin/unraid_view start

# Run as daemon
_build/prod/rel/unraid_view/bin/unraid_view daemon

# Stop release
_build/prod/rel/unraid_view/bin/unraid_view stop
```

## Manual Setup

To start your Phoenix server manually:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Rich Table Component

The application ships with a reusable `<.rich_table />` component
(`UnraidViewWeb.RichTableComponents`) that powers the home-page demo. You can
drop it into any LiveView by passing a list of rows and defining slots for the
columns you want to render:

```heex
<.rich_table
  id="workloads"
  rows={@rows}
  row_drop_event="workloads:row_dropped"
  row_click={fn row -> JS.patch(~p"/workloads/#{row.id}") end}
>
  <:col :let={slot} id="name" label="Name">
    <span class="font-semibold">{slot.row.name}</span>
  </:col>
  <:col :let={slot} id="owner" label="Owner">
    {slot.row.owner}
  </:col>
  <:col :let={slot} id="status" label="Status">
    <span class={["badge badge-sm", status_class(slot.row.status)]}>
      {slot.row.status}
    </span>
  </:col>
</.rich_table>
```

Rows are plain maps (or structs) and can include nested `:children` lists to
create folder hierarchies. The component emits LiveView events for row drops,
column resizing, column reordering, and drag lifecycle notifications so you can
persist the user’s intent.

### High-performance streaming

For ticker-like workloads (e.g. CPU/memory stats from a fleet of containers)
you can keep the DOM stable and stream only the cells that changed:

1. Render the table with `phx-update="ignore"` so LiveView does not attempt to
   re-render the body.
2. Mark the cells you want to patch with `data-row-field="status"`,
   `data-row-field="description"`, etc.
3. Periodically push a `"rich-table:pulse"` event via `push_event/3` that
   contains `{id, status, status_label, status_class, description, updated_at}`
   for just the rows that changed. Chunking the payload (see
   `RichTableDemoLive`) keeps LiveView and the browser fast.
4. The default hook listens for that event and updates the existing DOM nodes in
   place, so the UX remains smooth even when hundreds of rows update per second.

This pattern closely mirrors how you might tail `docker stats` or a stock-ticker
feed: LiveView coordinates access control, drag/drop, and layout, while the hook
handles the hot data path with minimal patching.

## Production Configuration

The app is pre-configured for demo purposes with:
- Fixed `SECRET_KEY_BASE` (change this in production!)
- Automatic server startup in production mode
- Pre-configured host allow-list for demo environments

For actual production deployment, ensure you:
1. Set a secure `SECRET_KEY_BASE` environment variable
2. Configure proper SSL certificates if needed
3. Review the security settings in `config/runtime.exs`

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
