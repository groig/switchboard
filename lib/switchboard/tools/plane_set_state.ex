defmodule Switchboard.Tools.PlaneSetState do
  @moduledoc "Moves a Plane work item to another state, by state name."
  use Switchboard.Tools.Support

  alias Switchboard.Plane

  @impl true
  def name, do: "plane_set_state"
  @impl true
  def title, do: "Change a Plane item's state"
  @impl true
  def description,
    do:
      "Moves a Plane work item to another state of its project (e.g. \"In Review\"), as you. " <>
        "The name is matched against the project's states (case, spacing and word order don't " <>
        "matter; the result says which state was used, and an unclear name lists the closest). This writes to Plane: before " <>
        "calling it, show the user the item, its current state and the new one, and get their " <>
        "explicit OK (confirm first). Returns the old and new state."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string", "description" => "Work item identifier, e.g. PROJ-123."},
        "state" => %{"type" => "string", "description" => "Target state name, as shown in Plane."}
      },
      "required" => ["id", "state"]
    }
  end

  @impl true
  def annotations, do: %{read_only: false, destructive: false, idempotent: true, open_world: true}
  @impl true
  def connections, do: [:plane]

  @impl true
  def aliases, do: Map.put(Switchboard.Tools.Support.task_aliases("id"), "status", "state")

  @impl true
  def example do
    %{
      args: %{"id" => "DEMO-12", "state" => "In Review"},
      output:
        "DEMO-12 (Export invoices as CSV): In Progress → **In Review**. https://projects.example.com/demo/browse/DEMO-12/"
    }
  end

  @impl true
  def call(scope, %{"id" => id, "state" => wanted}) do
    id = id |> String.trim() |> String.upcase()

    with true <- Plane.identifier?(id) || {:error, "id must look like PROJECT-123"},
         {:ok, cred} <- cred(scope, :plane),
         {:ok, item} <- Plane.fresh_item(cred, id) |> lift(id),
         {:ok, states} <- Plane.states(cred, scope.user.id, item["project"]) |> lift(id),
         {:ok, target, how} <- match_state(states, wanted) do
      old = get_in(item, ["state", "name"]) || "?"

      matched =
        if how == :closest,
          do: " (the closest state to \"#{cell(wanted)}\")",
          else: ""

      cond do
        target["id"] == get_in(item, ["state", "id"]) ->
          {:ok, "#{id} is already in **#{target["name"]}**#{matched}; nothing changed."}

        true ->
          case Plane.set_state(cred, item, target["id"]) do
            {:ok, _} ->
              {:ok,
               "#{id} (#{cell(item["name"], 100)}): #{cell(old)} → **#{cell(target["name"])}**#{matched}. #{Plane.browse_url(id)}"}

            {:error, reason} ->
              {:error, problem(:plane, reason)}
          end
      end
    end
  end

  @stopwords ~w(a an the in on of for to and is)

  @doc """
  Finds the state the person meant: the exact name (case-insensitive), then the same name with
  spacing and punctuation ignored, then by word overlap (reordered words, stop words ignored,
  `test`/`testing` count as the same word). Returns `{:ok, state, how}` with `how` `:exact` or
  `:closest`, or `{:error, message}` listing the best candidates first, then every state.
  """
  def match_state(states, wanted) do
    plain = &(&1 |> to_string() |> String.trim() |> String.downcase())
    compact = &(&1 |> plain.() |> String.replace(~r/[^\p{L}\p{N}]+/u, ""))

    with nil <- Enum.find(states, &(plain.(&1["name"]) == plain.(wanted))),
         nil <-
           compact.(wanted) != "" &&
             Enum.find(states, &(compact.(&1["name"]) == compact.(wanted))) do
      by_overlap(states, wanted)
    else
      state -> {:ok, state, :exact}
    end
  end

  defp by_overlap(states, wanted) do
    ranked =
      states
      |> Enum.map(&{&1, overlap(words(wanted), words(&1["name"]))})
      |> Enum.filter(fn {_s, score} -> score > 0 end)
      |> Enum.sort_by(fn {_s, score} -> -score end)

    all = states |> Enum.map(& &1["name"]) |> Enum.join(", ")

    wanted_words = words(wanted)

    case ranked do
      # The only state sharing words, and it has every word asked for.
      [{state, _}] ->
        if Enum.all?(wanted_words, fn w -> Enum.any?(words(state["name"]), &same_word?(w, &1)) end),
           do: {:ok, state, :closest},
           else: ambiguous(wanted, ranked, all)

      [{state, top} | [{_, second} | _]] when top >= 0.5 and top - second >= 0.25 ->
        {:ok, state, :closest}

      [_ | _] ->
        ambiguous(wanted, ranked, all)

      [] ->
        {:error, "\"#{cell(wanted)}\" is not a state of this project. Its states: #{all}."}
    end
  end

  defp ambiguous(wanted, ranked, all) do
    closest =
      case Enum.take(ranked, 3) do
        [{s, _}] -> "the closest is #{s["name"]}"
        top -> "the closest are: " <> Enum.map_join(top, ", ", fn {s, _} -> s["name"] end)
      end

    {:error,
     "\"#{cell(wanted)}\" isn't clearly one state of this project; #{closest}. " <>
       "Its states: #{all}. Ask the user which one and call again with the exact name."}
  end

  defp words(name) do
    all =
      name
      |> to_string()
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    case all -- @stopwords do
      [] -> Enum.uniq(all)
      some -> Enum.uniq(some)
    end
  end

  # Jaccard over words, where a word also matches one it is a prefix of (4+ letters).
  defp overlap([], _), do: 0
  defp overlap(_, []), do: 0

  defp overlap(a, b) do
    shared = Enum.count(a, fn w -> Enum.any?(b, &same_word?(w, &1)) end)
    shared / (length(a) + length(b) - shared)
  end

  defp same_word?(a, b),
    do:
      a == b or
        (min(String.length(a), String.length(b)) >= 4 and
           (String.starts_with?(a, b) or String.starts_with?(b, a)))

  defp lift({:error, :not_found}, id),
    do: {:error, "Plane has no work item #{id}, or you can't see it."}

  defp lift({:error, reason}, _id), do: {:error, problem(:plane, reason)}
  defp lift(ok, _id), do: ok
end
