defmodule Switchboard.RocketChat do
  @moduledoc """
  Rocket.Chat (8.x) client.

    * **As the person** (`post_as/3`): their own personal access token and user id, for messages
      they approve. Before posting to a channel it checks they are a member.
    * **As the bot user** (`notify/2`): an existing bot user's token (`ROCKETCHAT_BOT_USER_ID`,
      `ROCKETCHAT_BOT_TOKEN`), only ever for a direct message to the caller. Other automation may
      read that bot's DMs, so every notice ends with a line saying replies aren't read.
  """

  alias Switchboard.Upstreams

  @max_message 4_000

  def max_message, do: @max_message

  defp request(headers, opts) do
    Upstreams.request(:rocketchat, Keyword.put(opts, :headers, headers)) |> Upstreams.body()
  end

  defp personal(%{"token" => token, "user_id" => uid}),
    do: [{"x-auth-token", token}, {"x-user-id", uid}]

  defp bot do
    config = Upstreams.config(:rocketchat)

    case {config[:bot_user_id], config[:bot_token]} do
      {uid, token} when is_binary(uid) and uid != "" and is_binary(token) and token != "" ->
        {:ok, [{"x-auth-token", token}, {"x-user-id", uid}]}

      _ ->
        {:error, :not_configured}
    end
  end

  def base_url, do: Upstreams.base_url(:rocketchat)

  @doc """
  Whether a message text tries to notify everyone. `@all`, `@here` (and `@everyone`) are
  refused in Switchboard, whatever the person's permissions.
  """
  def mass_mention?(text), do: text =~ ~r/(^|[^\w@])@(all|here|everyone)\b/i

  @doc "Breaks @-mentions so a notice pings nobody (a zero-width space after each `@`)."
  def defuse_mentions(text), do: String.replace(text, "@", "@​")

  @doc """
  Posts `text` as the person to `target`: `#channel` (they must be a member) or `@username`
  (a direct message). Returns `{:ok, %{"permalink" => url, "room" => name}}`.
  """
  def post_as(cred, target, text) do
    headers = personal(cred)

    with {:ok, room} <- resolve_target(headers, cred, String.trim(target)),
         {:ok, %{"message" => msg}} <-
           request(headers,
             method: :post,
             url: "/api/v1/chat.postMessage",
             json: %{roomId: room.id, text: text}
           ) do
      {:ok, %{"room" => room.label, "permalink" => permalink(room, msg["_id"])}}
    end
  end

  defp resolve_target(headers, _cred, "@" <> username) do
    with :ok <- valid_name(username),
         {:ok, %{"room" => room}} <-
           request(headers, method: :post, url: "/api/v1/im.create", json: %{username: username}) do
      {:ok,
       %{
         id: room["_id"] || room["rid"],
         label: "@" <> username,
         path: "direct/#{room["_id"] || room["rid"]}"
       }}
    end
  end

  defp resolve_target(headers, cred, "#" <> name), do: channel(headers, cred, name)
  defp resolve_target(headers, cred, name), do: channel(headers, cred, name)

  defp channel(headers, cred, name) do
    with :ok <- valid_name(name),
         {:ok, %{"room" => room}} <-
           request(headers, url: "/api/v1/rooms.info", params: [roomName: name])
           |> not_found_as(:no_channel),
         {:ok, member?} <- member?(headers, room["_id"], cred) do
      if member? do
        kind = if room["t"] == "p", do: "group", else: "channel"
        {:ok, %{id: room["_id"], label: "#" <> name, path: "#{kind}/#{name}"}}
      else
        {:error, :not_member}
      end
    end
  end

  # The person has a subscription to the room exactly when they are a member of it.
  defp member?(headers, room_id, _cred) do
    case request(headers, url: "/api/v1/subscriptions.getOne", params: [roomId: room_id]) do
      {:ok, %{"subscription" => sub}} when is_map(sub) -> {:ok, true}
      {:ok, _} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      {:error, {:status, 400}} -> {:ok, false}
      error -> error
    end
  end

  defp not_found_as({:error, :not_found}, reason), do: {:error, reason}
  defp not_found_as({:error, {:status, 400}}, reason), do: {:error, reason}
  defp not_found_as(other, _), do: other

  defp valid_name(name) do
    if name =~ ~r/^[\w.\-]{1,80}$/u, do: :ok, else: {:error, :invalid_target}
  end

  defp permalink(room, msg_id), do: "#{base_url()}/#{room.path}?msg=#{msg_id}"

  ## The bot user

  @doc "A Rocket.Chat user by username, as the bot sees it (`username`, `name`, `active`)."
  def user_info(username) do
    with {:ok, headers} <- bot(),
         :ok <- valid_name(username),
         {:ok, %{"user" => user}} <-
           request(headers, url: "/api/v1/users.info", params: [username: username]) do
      {:ok, user}
    end
  end

  @doc "A direct message from the bot user to `username`."
  def notify(username, text) do
    with {:ok, headers} <- bot(),
         :ok <- valid_name(username),
         {:ok, %{"room" => room}} <-
           request(headers, method: :post, url: "/api/v1/im.create", json: %{username: username}),
         {:ok, %{"message" => _}} <-
           request(headers,
             method: :post,
             url: "/api/v1/chat.postMessage",
             json: %{roomId: room["_id"] || room["rid"], text: text}
           ) do
      :ok
    end
  end
end
