defmodule Unraid.Docker.TemplateAdapter do
  @moduledoc """
  Reads and writes XML template files from the boot drive.

  Template files are stored at `/boot/config/plugins/dockerMan/templates-user/`
  with the naming convention `my-{container-name}.xml`.

  This adapter maintains backwards compatibility with the webgui XML template format.
  """

  alias Unraid.Docker.Template

  @default_templates_path "/boot/config/plugins/dockerMan/templates-user"

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  @doc """
  Get the configured templates path.
  """
  def templates_path do
    Application.get_env(:unraid, :docker_templates_path, @default_templates_path)
  end

  # ---------------------------------------------------------------------------
  # Template Queries
  # ---------------------------------------------------------------------------

  @doc """
  List all user templates.

  Returns a list of `{name, path}` tuples.
  """
  def list_templates do
    path = templates_path()

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".xml"))
        |> Enum.map(fn filename ->
          name = extract_container_name(filename)
          {name, Path.join(path, filename)}
        end)
        |> Enum.sort_by(fn {name, _} -> name end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Read a template file by container name and parse to Template struct.

  Looks for the template at `my-{container_name}.xml`.
  """
  def read_template(container_name) when is_binary(container_name) do
    path = template_path(container_name)
    read_template_from_path(path)
  end

  @doc """
  Read a template from a specific file path.
  """
  def read_template_from_path(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        Template.from_xml(content)

      {:error, reason} ->
        {:error, {:file_read_error, reason, path}}
    end
  end

  @doc """
  Check if a template exists for the given container name.
  """
  def template_exists?(container_name) when is_binary(container_name) do
    path = template_path(container_name)
    File.exists?(path)
  end

  @doc """
  Get the file path for a container's template.
  """
  def template_path(container_name) when is_binary(container_name) do
    filename = "my-#{container_name}.xml"
    Path.join(templates_path(), filename)
  end

  # ---------------------------------------------------------------------------
  # Template Writes
  # ---------------------------------------------------------------------------

  @doc """
  Write a Template to its XML file.

  The file will be written to `my-{template.name}.xml`.
  """
  def write_template(%Template{} = template) do
    case Template.validate(template) do
      {:ok, _} ->
        path = template_path(template.name)
        xml_content = Template.to_xml(template)
        write_template_file(path, xml_content)

      {:error, errors} ->
        {:error, {:validation_failed, errors}}
    end
  end

  @doc """
  Write a template to a specific path (for backup or migration).
  """
  def write_template_to_path(%Template{} = template, path) when is_binary(path) do
    case Template.validate(template) do
      {:ok, _} ->
        xml_content = Template.to_xml(template)
        write_template_file(path, xml_content)

      {:error, errors} ->
        {:error, {:validation_failed, errors}}
    end
  end

  defp write_template_file(path, content) do
    # Ensure directory exists
    dir = Path.dirname(path)

    with :ok <- ensure_directory(dir),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} ->
        {:error, {:file_write_error, reason, path}}
    end
  end

  defp ensure_directory(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  @doc """
  Delete a template file by container name.
  """
  def delete_template(container_name) when is_binary(container_name) do
    path = template_path(container_name)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:file_delete_error, reason, path}}
    end
  end

  @doc """
  Rename a template (when container name changes).

  This copies the template to the new name and deletes the old one.
  """
  def rename_template(old_name, new_name) when is_binary(old_name) and is_binary(new_name) do
    old_path = template_path(old_name)
    new_path = template_path(new_name)

    with {:ok, template} <- read_template(old_name),
         updated_template = %{template | name: new_name},
         :ok <- write_template_to_path(updated_template, new_path),
         :ok <- File.rm(old_path) do
      {:ok, updated_template}
    end
  end

  @doc """
  Create a backup of a template before modification.

  Returns the backup path on success.
  """
  def backup_template(container_name) when is_binary(container_name) do
    source = template_path(container_name)
    timestamp = :os.system_time(:second)
    backup_path = "#{source}.backup.#{timestamp}"

    case File.cp(source, backup_path) do
      :ok -> {:ok, backup_path}
      {:error, reason} -> {:error, {:backup_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  @doc """
  Extract container name from template filename.

  "my-nginx.xml" -> "nginx"
  "my-my-container.xml" -> "my-container"
  """
  def extract_container_name(filename) when is_binary(filename) do
    filename
    |> String.trim_trailing(".xml")
    |> String.replace_prefix("my-", "")
  end

  @doc """
  Find templates matching a pattern.

  Useful for searching by partial container name.
  """
  def find_templates(pattern) when is_binary(pattern) do
    list_templates()
    |> Enum.filter(fn {name, _path} ->
      String.contains?(String.downcase(name), String.downcase(pattern))
    end)
  end

  @doc """
  Get template modification time.

  Returns DateTime or nil if file doesn't exist.
  """
  def template_modified_at(container_name) when is_binary(container_name) do
    path = template_path(container_name)

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        case DateTime.from_unix(mtime) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Import a template from another location (e.g., community templates).

  Copies the template to the user templates directory with the "my-" prefix.
  """
  def import_template(source_path, container_name) when is_binary(source_path) and is_binary(container_name) do
    with {:ok, template} <- read_template_from_path(source_path),
         updated_template = %{template | name: container_name},
         :ok <- write_template(updated_template) do
      {:ok, updated_template}
    end
  end
end
