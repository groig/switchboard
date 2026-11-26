defmodule Switchboard.Controls do
  @moduledoc """
  Live operational controls, stored in the database and applied on the next call:

    * global read-only mode (refuses every tool that isn't read-only);
    * a maintenance message (a banner in the web app and a note on tool results);
    * per-tool kill switches and rate limits.

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

  def subscribe, do: Phoenix.PubSub.subscribe(Switchboard.PubSub, @topic)

  ## Reads (cached)

  def read_only?, do: snapshot().global.read_only

  def maintenance_message do
    case snapshot().global.maintenance_message do
      msg when is_binary(msg) and msg != "" -> msg
      _ -> nil
    end
  end

  def tool_enabled?(name), do: Map.get(snapshot().tools, name, %{enabled: true}).enabled

  @doc "Calls per person per minute for a tool module."
  def rate_limit(tool_mod) do
    case Map.get(snapshot().tools, tool_mod.name()) do
      %{rate_limit: limit} when is_integer(limit) -> limit
      _ -> default_rate_limit(tool_mod)
    end
  end

  def default_rate_limit(tool_mod) do
    if tool_mod.annotations()[:read_only], do: @default_read_limit, else: @default_write_limit
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
        maintenance_message: global.maintenance_message
      })

      {:ok, global}
    end
  end

  def update_tool(%Scope{user: %{admin: true}} = scope, name, attrs) when is_binary(name) do
    control = Repo.get(ToolControl, name) || %ToolControl{tool: name}

    with {:ok, _mod} <- Switchboard.Tools.fetch(name),
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

  defp changed do
    reload()
    Phoenix.PubSub.broadcast_from(Switchboard.PubSub, self(), @topic, :controls_changed)
  end
end
