defmodule Switchboard.Plane.Images do
  @moduledoc """
  Images embedded in a Plane work item's description and comments.

  Plane stores pasted screenshots as `<image-component src="<asset uuid>" ...>` in
  `description_html` and `comment_html`; older content may carry a full URL in `src`, or a plain
  `<img src="...">`. `collect/2` turns that HTML into text with a numbered placeholder per image
  (`[image 1: <asset id>]`), numbering the description first and then the comments oldest to
  newest, so `plane_get_item` and `plane_get_image` agree on what "image 2" is. The same asset
  embedded twice keeps its first number.

  Only uploads to this Plane are fetchable: a `src` that is a bare UUID, or a URL on the Plane
  host whose path ends in one. Anything else (an image hot-linked from another site) is listed
  with its URL and never fetched.
  """

  alias Switchboard.{Markdown, Upstreams}

  @max 50
  @uuid ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
  @tag ~r/<(?:image-component|img)\b[^>]*>/i
  @whole_tag ~r/\A<(?:image-component|img)\b[^>]*>\z/i
  @src ~r/\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i

  @typedoc """
  One image: its number, the `asset_id` when it's an upload to this Plane (else nil), the `src`
  it was found with, and where it was found (`:description` or `{:comment, comment}`).
  """
  @type image :: %{
          n: pos_integer(),
          asset_id: String.t() | nil,
          src: String.t(),
          source: :description | {:comment, map()}
        }

  @doc "The most images numbered per work item; later ones show as `[image]`."
  def max, do: @max

  @doc """
  Text for an item's description and comments, with placeholders, and the images found.
  Returns `%{description: text, comments: [{comment, text}], images: [image], total: n}`, with
  the comments sorted oldest first and `total` counting images past the cap too.
  """
  def collect(item, comments) do
    sorted = Enum.sort_by(comments, &(&1["created_at"] || ""))
    acc = %{images: [], by_ref: %{}, total: 0}

    {description, acc} = text(item["description_html"], :description, acc)

    {texts, acc} =
      Enum.map_reduce(sorted, acc, fn c, acc -> text(c["comment_html"], {:comment, c}, acc) end)

    %{
      description: description,
      comments: Enum.zip(sorted, texts),
      images: Enum.reverse(acc.images),
      total: acc.total
    }
  end

  @doc """
  The text of one HTML fragment with its images replaced by placeholders, numbering from
  `acc` (see `collect/2`). Exposed for tests; callers use `collect/2`.
  """
  def text(nil, _source, acc), do: {"", acc}

  def text(html, source, acc) do
    {parts, acc} =
      @tag
      |> Regex.split(html, include_captures: true)
      |> Enum.map_reduce(acc, fn part, acc ->
        if part =~ @whole_tag, do: image(part, source, acc), else: {part, acc}
      end)

    text =
      parts
      |> Enum.join()
      |> Markdown.html_to_text()
      # One placeholder per line, without blank lines or indentation around it.
      |> String.replace(~r/\n+(?=\[image[\] ])/, "\n")
      |> String.replace(~r/^(\[image[^\]\n]*\])\n[ \t]+/m, "\\1\n")

    {text, acc}
  end

  defp image(tag, source, acc) do
    case src(tag) do
      nil ->
        {"\n[image]\n", acc}

      src ->
        asset_id = asset_id(src)
        ref = asset_id || src

        case acc.by_ref do
          %{^ref => n} ->
            {placeholder(n, ref), acc}

          _ when acc.total >= @max ->
            {"\n[image]\n", %{acc | total: acc.total + 1}}

          _ ->
            n = acc.total + 1
            entry = %{n: n, asset_id: asset_id, src: src, source: source}

            {placeholder(n, ref),
             %{
               acc
               | images: [entry | acc.images],
                 by_ref: Map.put(acc.by_ref, ref, n),
                 total: n
             }}
        end
    end
  end

  # On its own line, as Plane shows images as blocks; html_to_text drops the extra blank lines.
  defp placeholder(n, ref), do: "\n[image #{n}: #{Markdown.truncate(ref, 200)}]\n"

  defp src(tag) do
    case Regex.run(@src, tag, capture: :all_but_first) do
      nil -> nil
      groups -> groups |> Enum.find(&(&1 != "")) |> unescape()
    end
  end

  defp unescape(nil), do: nil
  defp unescape(s), do: s |> String.replace("&amp;", "&") |> String.trim() |> blank()

  defp blank(""), do: nil
  defp blank(s), do: s

  @doc """
  The asset UUID for a `src`: a bare UUID, or the last UUID in the path of a URL on the Plane
  host (or a relative one). nil for anything else.
  """
  def asset_id(src) do
    cond do
      src =~ ~r/\A#{@uuid.source}\z/i ->
        String.downcase(src)

      plane_url?(src) ->
        case Regex.scan(@uuid, URI.parse(src).path || "") do
          [] -> nil
          found -> found |> List.last() |> hd() |> String.downcase()
        end

      true ->
        nil
    end
  end

  defp plane_url?(src) do
    case URI.parse(src) do
      %URI{scheme: nil, host: nil, path: "/" <> _} -> true
      %URI{} = uri -> same_origin?(uri, URI.parse(Upstreams.base_url(:plane)))
    end
  end

  @doc "Whether a URL has the configured Plane URL's scheme, host and port."
  def plane_origin?(url) when is_binary(url),
    do: same_origin?(URI.parse(url), URI.parse(Upstreams.base_url(:plane)))

  def plane_origin?(_), do: false

  defp same_origin?(%URI{scheme: s, host: h, port: p}, %URI{scheme: s2, host: h2, port: p2})
       when is_binary(s) and is_binary(h) and is_binary(h2) do
    String.downcase(s) == String.downcase(s2 || "") and String.downcase(h) == String.downcase(h2) and
      p == p2
  end

  defp same_origin?(_, _), do: false

  @doc "Finds an image by number (`\"2\"`, `2`) or asset UUID; `:error` if it isn't there."
  def find(images, ref) when is_integer(ref), do: find_by(images, &(&1.n == ref))

  def find(images, ref) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      ref =~ ~r/\A#?\d{1,4}\z/ ->
        find(images, ref |> String.trim_leading("#") |> String.to_integer())

      ref =~ ~r/\A#{@uuid.source}\z/i ->
        id = String.downcase(ref)
        find_by(images, &(&1.asset_id == id))

      true ->
        :error
    end
  end

  def find(_images, _ref), do: :error

  defp find_by(images, fun) do
    case Enum.find(images, fun) do
      nil -> :error
      image -> {:ok, image}
    end
  end

  @doc "Whether `ref` has the shape of an image number or an asset UUID."
  def valid_ref?(ref) when is_integer(ref), do: ref > 0

  def valid_ref?(ref) when is_binary(ref),
    do: String.trim(ref) =~ ~r/\A(#?\d{1,4}|#{@uuid.source})\z/i

  def valid_ref?(_), do: false

  ## Image bytes

  @allowed %{
    "image/png" => :png,
    "image/jpeg" => :jpeg,
    "image/gif" => :gif,
    "image/webp" => :webp
  }

  # Object stores sometimes serve uploads without a precise type; the magic bytes decide then.
  @generic ["application/octet-stream", "binary/octet-stream"]

  @doc """
  Checks downloaded bytes: the declared `Content-Type` must be an allowed raster type (or a
  generic binary type) and the magic bytes must be PNG, JPEG, GIF or WebP, agreeing with the
  declared type. Returns `{:ok, mime_type}` or `{:error, :not_an_image}`. SVG and anything else
  that can carry script is refused.
  """
  def check(content_type, bytes) when is_binary(bytes) do
    declared =
      content_type
      |> to_string()
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    sniffed = sniff(bytes)

    cond do
      sniffed == nil -> {:error, :not_an_image}
      Map.get(@allowed, declared) == sniffed -> {:ok, mime(sniffed)}
      declared in @generic -> {:ok, mime(sniffed)}
      true -> {:error, :not_an_image}
    end
  end

  def check(_content_type, _bytes), do: {:error, :not_an_image}

  defp sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: :png
  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: :jpeg
  defp sniff(<<"GIF8", v, "a", _::binary>>) when v in [?7, ?9], do: :gif
  defp sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: :webp
  defp sniff(_), do: nil

  defp mime(type), do: Enum.find_value(@allowed, fn {m, t} -> t == type && m end)
end
