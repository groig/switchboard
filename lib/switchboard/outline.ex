defmodule Switchboard.Outline do
  @moduledoc "Read-only client for Outline's API (1.x), with the caller's own API key."

  alias Switchboard.Upstreams

  defp post(%{"token" => token}, method, body) do
    Upstreams.request(:outline,
      method: :post,
      url: "/api/" <> method,
      json: body,
      auth: {:bearer, token}
    )
    |> Upstreams.body()
  end

  @doc "Full-text search: `[%{title, url, url_id, context, updated_at}]`."
  def search(cred, query, opts \\ []) do
    body = %{
      query: query,
      limit: Keyword.get(opts, :limit, 10),
      offset: Keyword.get(opts, :offset, 0)
    }

    with {:ok, %{"data" => data}} <- post(cred, "documents.search", body) do
      {:ok,
       Enum.map(data, fn hit ->
         doc = hit["document"] || %{}

         %{
           "title" => doc["title"],
           "url" => absolute(doc["url"]),
           "url_id" => doc["urlId"],
           "context" => hit["context"],
           "updated_at" => doc["updatedAt"]
         }
       end)}
    end
  end

  @doc "A document by UUID or urlId: `%{title, url, text, updated_at}` (text is Markdown)."
  def info(cred, id) do
    with {:ok, params} <- document_params(id),
         {:ok, %{"data" => doc}} <- post(cred, "documents.info", params) do
      {:ok,
       %{
         "title" => doc["title"],
         "url" => absolute(doc["url"]),
         "text" => doc["text"] || "",
         "updated_at" => doc["updatedAt"]
       }}
    end
  end

  @doc """
  Creates a **draft** in the person's account (`publish: false`). Refuses to report success if
  Outline says the document was published anyway.
  """
  def create_draft(cred, title, text, collection_id \\ nil) do
    body =
      %{title: title, text: text, publish: false}
      |> then(&if(collection_id, do: Map.put(&1, :collectionId, collection_id), else: &1))

    case post(cred, "documents.create", body) do
      {:ok, %{"data" => %{"publishedAt" => published}}} when not is_nil(published) ->
        {:error, :published}

      {:ok, %{"data" => doc}} ->
        {:ok, %{"title" => doc["title"], "url" => absolute(doc["url"]), "url_id" => doc["urlId"]}}

      {:ok, _} ->
        {:error, :unexpected_response}

      error ->
        error
    end
  end

  @doc "Extracts a document id (urlId) from an Outline URL, or returns the input."
  def document_id(input) do
    case Regex.run(~r"/doc/(?:[^/?#]*-)?([A-Za-z0-9]{10})(?:[/?#]|$)", input) do
      [_, id] -> id
      _ -> String.trim(input)
    end
  end

  defp document_params(input) do
    uri = URI.parse(input)
    base = URI.parse(Upstreams.base_url(:outline))

    cond do
      is_nil(uri.host) && is_nil(uri.scheme) && !String.contains?(input, "/") ->
        {:ok, %{id: input}}

      {uri.scheme, uri.host, uri.port} != {base.scheme, base.host, base.port} ->
        {:error, :invalid_document_url}

      true ->
        case String.split(uri.path || "", "/", trim: true) do
          ["s", share] -> {:ok, %{shareId: share}}
          ["doc", _slug] -> {:ok, %{id: document_id(uri.path)}}
          ["s", share, "doc", slug] -> {:ok, %{shareId: share, id: document_id("/doc/" <> slug)}}
          _ -> {:error, :invalid_document_url}
        end
    end
  end

  defp absolute(nil), do: nil
  defp absolute("/" <> _ = path), do: Upstreams.base_url(:outline) <> path
  defp absolute(url), do: url
end
