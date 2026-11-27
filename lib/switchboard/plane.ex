defmodule Switchboard.Plane do
  @moduledoc """
  Read-only client for Plane's public API (v1.4; images need v1.5), with the caller's own API key.

  Notes from the real instance:

    * the API has no server-side assignee filter, so "my items" scans the projects the person is
      a member of, ordered by state group (backlog, unstarted, started, completed, cancelled)
      and stops at the first closed item: open items cost a page or two per project;
    * `expand=state` returns the state object (name, group);
    * the API key allows about 60 requests a minute, shared with anything else using it.

  Projects, states and `users/me` are cached per person for a few minutes.
  """

  alias Switchboard.{Cache, Upstreams}

  @cache_ttl :timer.minutes(10)
  @read_ttl :timer.seconds(45)
  @open_groups ~w(backlog unstarted started)
  @item_fields "id,name,sequence_id,state,assignees,priority,target_date,start_date,updated_at,project,completed_at"

  def workspace, do: Upstreams.config(:plane)[:workspace]

  @doc "The browser URL of a work item."
  def browse_url(identifier),
    do: "#{Upstreams.base_url(:plane)}/#{workspace()}/browse/#{identifier}/"

  # Every GET is cached per key for @read_ttl: people's keys are shared with their other tools
  # (about 60 requests a minute), so repeated my_work calls must not burn the budget. Errors are
  # not cached. Writes drop the key's cached reads.
  defp get(%{"token" => key} = cred, path, params \\ []) do
    Cache.fetch({:plane_get, key_id(cred), path, params}, @read_ttl, fn ->
      Upstreams.request(:plane,
        url: "/api/v1" <> path,
        params: params,
        headers: [{"x-api-key", key}]
      )
      |> Upstreams.body()
    end)
  end

  defp write(%{"token" => key} = cred, method, path, body) do
    result =
      Upstreams.request(:plane,
        method: method,
        url: "/api/v1" <> path,
        json: body,
        headers: [{"x-api-key", key}]
      )
      |> Upstreams.body()

    forget(cred)
    result
  end

  @doc "Drops every cached read for a key (after a write)."
  def forget(cred) do
    kid = key_id(cred)
    Cache.delete_match({:plane_get, kid, :_, :_})
    Cache.delete_match({:plane_my_items, :_, kid})
  end

  defp ws_path(rest), do: "/workspaces/#{workspace()}" <> rest

  @doc "The key's user (`id`, `display_name`, `email`...)."
  def me(cred, user_id) do
    Cache.fetch({:plane_me, user_id, key_id(cred)}, @cache_ttl, fn -> get(cred, "/users/me/") end)
  end

  @doc "Projects the key can see (`id`, `identifier`, `name`, `is_member`)."
  def projects(cred, user_id) do
    Cache.fetch({:plane_projects, user_id, key_id(cred)}, @cache_ttl, fn ->
      with {:ok, %{"results" => results}} <- get(cred, ws_path("/projects/"), per_page: 100) do
        {:ok, Enum.map(results, &Map.take(&1, ~w(id identifier name is_member)))}
      end
    end)
  end

  # Different keys (after relinking) must not share cache entries.
  defp key_id(%{"token" => key}), do: :crypto.hash(:sha256, key) |> binary_part(0, 8)

  @doc """
  Open work items assigned to the key's user in the projects they are a member of. Returns
  `{:ok, items, notes}`; `notes` lists projects that couldn't be read.
  """
  def my_items(cred, user_id) do
    Cache.fetch({:plane_my_items, user_id, key_id(cred)}, @read_ttl, fn ->
      with {:ok, items, notes} <- fetch_my_items(cred, user_id), do: {:ok, {items, notes}}
    end)
    |> case do
      {:ok, {items, notes}} -> {:ok, items, notes}
      error -> error
    end
  end

  @doc "The `my_items/2` result if it is cached right now (`{:ok, items}`), without calling Plane."
  def cached_my_items(cred, user_id) do
    case Cache.peek({:plane_my_items, user_id, key_id(cred)}) do
      {:ok, {items, _notes}} -> {:ok, items}
      :error -> :error
    end
  end

  defp fetch_my_items(cred, user_id) do
    with {:ok, me} <- me(cred, user_id),
         {:ok, projects} <- projects(cred, user_id) do
      member = Enum.filter(projects, & &1["is_member"])

      results =
        member
        |> Task.async_stream(&open_items(cred, &1, me["id"]),
          timeout: 15_000,
          on_timeout: :kill_task,
          max_concurrency: 4
        )
        |> Enum.zip(member)

      items = for {{:ok, {:ok, items}}, _p} <- results, item <- items, do: item

      notes =
        for {result, p} <- results, not match?({:ok, {:ok, _}}, result) do
          reason =
            case result do
              {:ok, {:error, r}} -> r
              {:exit, :timeout} -> :timeout
              _ -> :crashed
            end

          "#{p["identifier"]}: " <> Upstreams.problem(:plane, reason)
        end

      {:ok, items, notes}
    end
  end

  defp open_items(cred, project, me_id, cursor \\ nil, pages \\ 0, acc \\ []) do
    params =
      [per_page: 100, order_by: "state__group", expand: "state", fields: @item_fields] ++
        if(cursor, do: [cursor: cursor], else: [])

    with {:ok, body} <- get(cred, ws_path("/projects/#{project["id"]}/work-items/"), params) do
      results = body["results"] || []
      {open, closed} = Enum.split_with(results, &(get_in(&1, ["state", "group"]) in @open_groups))

      mine =
        for item <- open,
            me_id in (item["assignees"] || []),
            do: Map.put(item, "identifier", "#{project["identifier"]}-#{item["sequence_id"]}")

      acc = acc ++ mine

      if closed == [] and body["next_page_results"] and pages < 4,
        do: open_items(cred, project, me_id, body["next_cursor"], pages + 1, acc),
        else: {:ok, acc}
    end
  end

  @doc """
  Work items in the person's member projects updated since `since`, that are assigned to them or
  that they created (Plane's API has no per-person activity feed). One page per project, newest
  first; returns `{:ok, items, notes}` like `my_items/2`.
  """
  def recent_items(cred, user_id, %DateTime{} = since) do
    with {:ok, me} <- me(cred, user_id),
         {:ok, projects} <- projects(cred, user_id) do
      member = Enum.filter(projects, & &1["is_member"])

      results =
        member
        |> Task.async_stream(&recent_in(cred, &1, me["id"], since),
          timeout: 15_000,
          on_timeout: :kill_task,
          max_concurrency: 4
        )
        |> Enum.zip(member)

      items = for {{:ok, {:ok, items}}, _p} <- results, item <- items, do: item

      notes =
        for {result, p} <- results, not match?({:ok, {:ok, _}}, result) do
          reason =
            case result do
              {:ok, {:error, r}} -> r
              {:exit, :timeout} -> :timeout
              _ -> :crashed
            end

          "#{p["identifier"]}: " <> Upstreams.problem(:plane, reason)
        end

      {:ok, Enum.sort_by(items, & &1["updated_at"], :desc), notes}
    end
  end

  defp recent_in(cred, project, me_id, since) do
    params = [
      per_page: 50,
      order_by: "-updated_at",
      expand: "state",
      fields: @item_fields <> ",created_by"
    ]

    with {:ok, body} <- get(cred, ws_path("/projects/#{project["id"]}/work-items/"), params) do
      items =
        for item <- body["results"] || [],
            updated_since?(item["updated_at"], since),
            me_id in (item["assignees"] || []) or item["created_by"] == me_id,
            do: Map.put(item, "identifier", "#{project["identifier"]}-#{item["sequence_id"]}")

      {:ok, items}
    end
  end

  defp updated_since?(at, since) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.compare(dt, since) != :lt
      _ -> false
    end
  end

  defp updated_since?(_at, _since), do: false

  @doc "A work item by its identifier (`PROJ-123`), with state, assignees and labels."
  def item(cred, identifier) do
    get(cred, ws_path("/work-items/#{identifier}/"), expand: "state,assignees,labels")
  end

  def comments(cred, item),
    do: list(cred, "/projects/#{item["project"]}/work-items/#{item["id"]}/comments/")

  def links(cred, item),
    do: list(cred, "/projects/#{item["project"]}/work-items/#{item["id"]}/links/")

  defp list(cred, path) do
    with {:ok, body} <- get(cred, ws_path(path), per_page: 50) do
      {:ok, if(is_list(body), do: body, else: body["results"] || [])}
    end
  end

  @doc """
  An uploaded asset (an image in a description or comment): `asset_url` (presigned, on the Plane
  host), `asset_name`, `asset_type`. Needs Plane 1.5+ (1.4 answers 500) and, from 1.5, membership
  of the asset's project (403 otherwise).
  """
  def asset(cred, asset_id), do: get(cred, ws_path("/assets/#{asset_id}/"))

  @image_cap 5_000_000

  @doc """
  Downloads an asset's presigned URL **without** the API key (the URL carries its own
  signature). Refuses URLs that aren't on the Plane host. Returns `{:ok, content_type, bytes}`
  or `{:error, reason}` (`:foreign_host`, `:too_large`, a status...). Capped at 5 MB.
  """
  def download(url) do
    if Switchboard.Plane.Images.plane_origin?(url) do
      case Upstreams.request(:plane,
             url: url,
             max_body: @image_cap,
             headers: [accept: "image/png, image/jpeg, image/gif, image/webp"]
           ) do
        {:ok, %Req.Response{status: 200, body: body} = resp} when is_binary(body) ->
          {:ok, resp |> Req.Response.get_header("content-type") |> List.first(), body}

        {:ok, %Req.Response{status: 200}} ->
          {:error, :not_an_image}

        other ->
          Upstreams.body(other)
      end
    else
      {:error, :foreign_host}
    end
  end

  def image_cap, do: @image_cap

  @doc "Search by title text or identifier across the workspace (`id`, `name`, `identifier`)."
  def search(cred, query, limit \\ 15) do
    with {:ok, %{"issues" => issues}} <-
           get(cred, ws_path("/work-items/search/"),
             search: query,
             limit: limit,
             workspace_search: "true"
           ) do
      {:ok,
       Enum.map(issues, fn i ->
         Map.put(i, "identifier", "#{i["project__identifier"]}-#{i["sequence_id"]}")
       end)}
    end
  end

  @doc "Workspace members as a map of id => display name, cached."
  def members(cred, user_id) do
    Cache.fetch({:plane_members, user_id, key_id(cred)}, @cache_ttl, fn ->
      with {:ok, body} <- get(cred, ws_path("/members/")) do
        list = if is_list(body), do: body, else: body["results"] || []
        {:ok, Map.new(list, &{&1["id"], &1["display_name"] || &1["email"]})}
      end
    end)
  end

  @doc "A project's states (`name`, `group`), cached."
  def states(cred, user_id, project_id) do
    Cache.fetch({:plane_states, user_id, project_id, key_id(cred)}, @cache_ttl, fn ->
      with {:ok, body} <- get(cred, ws_path("/projects/#{project_id}/states/"), per_page: 100) do
        {:ok, Enum.map(body["results"] || [], &Map.take(&1, ~w(id name group)))}
      end
    end)
  end

  ## Writes (the person's own key only)

  @doc "Adds a comment (plain text, escaped and turned into paragraphs) to a work item."
  def comment(cred, item, text) do
    html =
      text
      |> String.split(~r/\n{2,}/)
      |> Enum.map_join("", fn para ->
        escaped = para |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        "<p>" <> String.replace(escaped, "\n", "<br>") <> "</p>"
      end)

    write(
      cred,
      :post,
      ws_path("/projects/#{item["project"]}/work-items/#{item["id"]}/comments/"),
      %{
        "comment_html" => html
      }
    )
  end

  @doc "Moves a work item to another state (by state id)."
  def set_state(cred, item, state_id) do
    write(cred, :patch, ws_path("/projects/#{item["project"]}/work-items/#{item["id"]}/"), %{
      "state" => state_id
    })
  end

  @doc "Reads a work item bypassing the cache (before a write)."
  def fresh_item(cred, identifier) do
    forget(cred)
    item(cred, identifier)
  end

  @doc "Whether a string looks like a work item identifier (`PROJ-123`)."
  def identifier?(s) when is_binary(s), do: s =~ ~r/^[A-Za-z][A-Za-z0-9]{0,11}-\d{1,7}$/
  def identifier?(_), do: false

  @priority_order %{"urgent" => 0, "high" => 1, "medium" => 2, "low" => 3, "none" => 4}

  @doc "Sorts items: overdue and due soonest first, then by priority."
  def sort_items(items, today \\ Date.utc_today()) do
    Enum.sort_by(items, fn i ->
      due =
        case i["target_date"] && Date.from_iso8601(String.slice(i["target_date"], 0, 10)) do
          {:ok, d} -> Date.diff(d, today)
          _ -> 100_000
        end

      {due, Map.get(@priority_order, i["priority"], 5)}
    end)
  end
end
