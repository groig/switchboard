defmodule Switchboard.Controls do
  @moduledoc """
  Live operational controls, stored in the database and applied on the next call:

    * global read-only mode (refuses every tool that isn't read-only);
    * a maintenance message (a banner in the web app and a note on tool results);
    * pausing every watch (no new watches, no polling, no notices);
    * per-tool kill switches and rate limits;
    * per-workflow kill switches and rate limits, stored like a tool's under
      `"workflow:<name>"` (`Switchboard.Workflows.control_key/1`).

  Reads come from a `:persistent_term` snapshot, so the hot path (every tool call) never hits
  the database. Writes reload the snapshot and broadcast on `"controls"` so other nodes and open
  admin pages refresh.
  """
  import Ecto.Query

  alias Switchboard.Controls.{Global, ToolControl}
  alias Switchboard.{Audit, Repo, Scope}

  @key {__MODULE__, :snapshot}
  # Tests read the database every time, so each test's sandbox sees only its own controls.
  @cache Application.compile_env(:switchboard, [__MODULE__, :cache], true)
  @topic "controls"

  # Default calls per person per minute.
  @default_read_limit 60
  @default_write_limit 10
  # A workflow fans out to several systems (and spends the person's Plane budget).
  @default_workflow_limit 10

  def subscribe, do: Phoenix.PubSub.subscribe(Switchboard.PubSub, @topic)

  ## Reads (cached)

  def read_only?, do: snapshot().global.read_only

  @doc "Whether watches are paused (no new watches, no polling, no notices)."
  def watches_paused?, do: snapshot().global.watches_paused == true

  def maintenance_message do
    case snapshot().global.maintenance_message do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> nil
    end
  end

  @doc "Whether a tool (by name) or a workflow (by `workflow:<name>`) is switched on."
  def tool_enabled?(key), do: Map.get(snapshot().tools, key, %{enabled: true}).enabled

  @doc "Calls per person per minute for a tool or workflow module."
  def rate_limit(mod) do
    case Map.get(snapshot().tools, control_key(mod)) do
      %{rate_limit: limit} when is_integer(limit) -> limit
      _ -> default_rate_limit(mod)
    end
  end

  def default_rate_limit(mod) do
    cond do
      Switchboard.Workflows.workflow?(mod) -> @default_workflow_limit
      mod.annotations()[:read_only] -> @default_read_limit
      true -> @default_write_limit
    end
  end

  @doc "The controls key of a tool module (its name) or a workflow module (`workflow:<name>`)."
  def control_key(mod) do
    if Switchboard.Workflows.workflow?(mod),
      do: Switchboard.Workflows.control_key(mod.name()),
      else: mod.name()
  end

  def global, do: snapshot().global
  def tool_controls, do: snapshot().tools

  defp snapshot do
    if @cache do
      case :persistent_term.get(@key, nil) do
        nil -> reload()
        snapshot -> snapshot
      end
    else
      load()
    end
  end

  @doc "Re-reads the controls from the database."
  def reload do
    snapshot = load()
    if @cache, do: :persistent_term.put(@key, snapshot)
    snapshot
  end

  defp load do
    global = Repo.get(Global, 1) || %Global{id: 1}
    tools = Repo.all(ToolControl) |> Map.new(&{&1.tool, &1})
    %{global: global, tools: tools}
  end

  @doc false
  # Forgets the snapshot (tests, and other nodes after a broadcast).
  def invalidate, do: :persistent_term.erase(@key)

  ## Writes (admin)

  def change_global(attrs \\ %{}), do: Global.changeset(global(), attrs)

  def update_global(%Scope{user: %{admin: true}} = scope, attrs) do
    global = Repo.get(Global, 1) || %Global{id: 1}

    with {:ok, global} <- global |> Global.changeset(attrs) |> Repo.insert_or_update() do
      changed()

      Audit.log_web(scope, "admin.controls_updated", %{
        read_only: global.read_only,
        maintenance_message: global.maintenance_message,
        watches_paused: global.watches_paused
      })

      {:ok, global}
    end
  end

  def update_tool(%Scope{user: %{admin: true}} = scope, name, attrs) when is_binary(name) do
    control = Repo.get(ToolControl, name) || %ToolControl{tool: name}

    with {:ok, _mod} <- fetch_controlled(name),
         {:ok, control} <- control |> ToolControl.changeset(attrs) |> Repo.insert_or_update() do
      changed()

      Audit.log_web(scope, "admin.tool_updated", %{
        tool: name,
        enabled: control.enabled,
        rate_limit: control.rate_limit
      })

      {:ok, control}
    end
  end

  @doc "Drops a tool's overrides (back to enabled with its default limit)."
  def reset_tool(%Scope{user: %{admin: true}} = scope, name) do
    Repo.delete_all(from t in ToolControl, where: t.tool == ^name)
    changed()
    Audit.log_web(scope, "admin.tool_reset", %{tool: name})
    :ok
  end

  # Tools by name, workflows by `workflow:<name>`.
  defp fetch_controlled("workflow:" <> name), do: Switchboard.Workflows.fetch(name)
  defp fetch_controlled(name), do: Switchboard.Tools.fetch(name)

  defp changed do
    reload()
    Phoenix.PubSub.broadcast_from(Switchboard.PubSub, self(), @topic, :controls_changed)
  end
end
