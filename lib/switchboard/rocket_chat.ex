defmodule Switchboard.RocketChat do
  @moduledoc """
  Rocket.Chat (8.x) client.

    * **As the person** (`post_as/3`): their own personal access token and user id, for messages
      they approve. Before posting to a channel it checks they are a member.
    * **Reading as the person** (`subscriptions/2`, `rooms/2`, `history/5`...): GET only, and
      never an endpoint that changes read state (`subscriptions.read`, `chat.readThread`...).
    * **As the bot user** (`notify/2`): an existing bot user's token (`ROCKETCHAT_BOT_USER_ID`,
      `ROCKETCHAT_BOT_TOKEN`), only ever for a direct message to the watch owner or the caller of
      `notify_me`. Other automation may read that bot's DMs, so every notice ends with a line
      saying replies aren't read.

  **Rate limits.** Rocket.Chat 8.x limits REST calls to 10 per minute per route *and client IP*
  (`API_Enable_Rate_Limiter_Limit_Calls_Default`), so every person's calls through Switchboard
  share one bucket per route. The bot role bypasses it (`api-bypass-rate-limit`). Calls with a
  person's token therefore spend a per-route budget kept here (`:route_budget`, from
  `ROCKETCHAT_ROUTE_BUDGET`; default 8 a minute, per node); past it they fail fast with `:rate_limited` instead of reaching Rocket.Chat.
  """

  alias Switchboard.{Cache, RateLimit, Upstreams}

  @max_message 4_000

  def max_message, do: @max_message

  defp request(headers, opts) do
    with :ok <- budget(headers, opts[:url]) do
      Upstreams.request(:rocketchat, Keyword.put(opts, :headers, headers)) |> Upstreams.body()
    end
  end

  # The bot user bypasses Rocket.Chat's limiter; everyone else shares it.
  defp budget(headers, url) do
    bot_id = Upstreams.config(:rocketchat)[:bot_user_id]
    uid = List.keyfind(headers, "x-user-id", 0)

    if bot_id not in [nil, ""] and uid == {"x-user-id", bot_id} do
      :ok
    else
      per_minute = Upstreams.config(:rocketchat)[:route_budget] || 8

      case RateLimit.take({:rocketchat_route, url}, per_minute, 60_000) do
        :ok -> :ok
        {:error, _} -> {:error, :rate_limited}
      end
    end
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
    case deliver(username, text) do
      :ok -> :ok
      {:error, {_stage, reason}} -> {:error, reason}
    end
  end

  @doc """
  Like `notify/2`, but says whether a failure may have posted anyway:
  `{:error, {:not_sent, reason}}` (safe to retry: the post was refused or never attempted) or
  `{:error, {:unsure, reason}}` (the post timed out or the connection broke; retrying could send
  it twice). Watch notices use it so a retry never duplicates a DM.
  """
  def deliver(username, text) do
    with {:ok, headers} <- bot() |> stage(:not_sent),
         :ok <- valid_name(username) |> stage(:not_sent),
         {:ok, room} <-
           request(headers, method: :post, url: "/api/v1/im.create", json: %{username: username})
           |> room_or_error() do
      request(headers,
        method: :post,
        url: "/api/v1/chat.postMessage",
        json: %{roomId: room["_id"] || room["rid"], text: text}
      )
      |> case do
        {:ok, %{"message" => _}} -> :ok
        {:ok, _} -> {:error, {:unsure, :unexpected_response}}
        {:error, reason} when reason in [:timeout, :too_large] -> {:error, {:unsure, reason}}
        {:error, {:transport, _} = reason} -> {:error, {:unsure, reason}}
        {:error, reason} -> {:error, {:not_sent, reason}}
      end
    end
  end

  defp stage({:error, reason}, stage), do: {:error, {stage, reason}}
  defp stage(ok, _stage), do: ok

  defp room_or_error({:ok, %{"room" => room}}) when is_map(room), do: {:ok, room}
  defp room_or_error({:ok, _}), do: {:error, {:not_sent, :unexpected_response}}
  defp room_or_error({:error, reason}), do: {:error, {:not_sent, reason}}

  ## Reading as the person (GET only; nothing here changes read state)

  defp get(cred, url, params),
    do: request(personal(cred), method: :get, url: url, params: params)

  @doc "The person's subscriptions updated since `since` (`update` list)."
  def subscriptions(cred, %DateTime{} = since) do
    with {:ok, %{"update" => subs}} when is_list(subs) <-
           get(cred, "/api/v1/subscriptions.get", updatedSince: DateTime.to_iso8601(since))
           |> shape() do
      {:ok, subs}
    end
  end

  @doc "The person's rooms updated since `since`, with `lastMessage`."
  def rooms(cred, %DateTime{} = since) do
    with {:ok, %{"update" => rooms}} when is_list(rooms) <-
           get(cred, "/api/v1/rooms.get", updatedSince: DateTime.to_iso8601(since)) |> shape() do
      {:ok, rooms}
    end
  end

  @doc "The person's subscription to a room (`nil` when they aren't a member)."
  def subscription(cred, room_id) do
    case get(cred, "/api/v1/subscriptions.getOne", roomId: room_id) do
      {:ok, %{"subscription" => sub}} when is_map(sub) -> {:ok, sub}
      {:ok, _} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, {:status, 400}} -> {:ok, nil}
      error -> error
    end
  end

  @doc "A channel or private group by name (`{:error, :no_channel}` when unknown)."
  def room_by_name(cred, name) do
    with :ok <- valid_name(name),
         {:ok, %{"room" => room}} <-
           get(cred, "/api/v1/rooms.info", roomName: name) |> not_found_as(:no_channel) do
      {:ok, room}
    end
  end

  @doc "Latest messages of a room the person is in, newest first. `t` is the room type."
  def history(cred, t, room_id, latest, count) do
    url =
      case t do
        "d" -> "/api/v1/im.history"
        "p" -> "/api/v1/groups.history"
        _ -> "/api/v1/channels.history"
      end

    params =
      [roomId: room_id, count: count, showThreadMessages: "false"] ++
        if(latest, do: [latest: DateTime.to_iso8601(latest)], else: [])

    with {:ok, %{"messages" => msgs}} when is_list(msgs) <- get(cred, url, params) |> shape() do
      {:ok, msgs}
    end
  end

  @doc "The latest messages of the person's DM with `username`, newest first (no DM is created)."
  def dm_messages(cred, username, count) do
    with :ok <- valid_name(username),
         {:ok, %{"messages" => msgs}} when is_list(msgs) <-
           get(cred, "/api/v1/im.messages", username: username, count: count, sort: ~s({"ts":-1}))
           |> not_found_as(:no_dm)
           |> shape() do
      {:ok, msgs}
    end
  end

  @doc "One message by id."
  def message(cred, id) do
    with {:ok, %{"message" => msg}} when is_map(msg) <-
           get(cred, "/api/v1/chat.getMessage", msgId: id) |> not_found_as(:no_message) |> shape() do
      {:ok, msg}
    end
  end

  @doc "A thread's latest replies (without the parent), newest first."
  def thread_messages(cred, tmid, count) do
    with {:ok, %{"messages" => msgs} = body} when is_list(msgs) <-
           get(cred, "/api/v1/chat.getThreadMessages",
             tmid: tmid,
             count: count,
             sort: ~s({"ts":-1})
           )
           |> shape() do
      {:ok, msgs, body["total"]}
    end
  end

  @doc "Messages in a room that @-mention the person, newest first."
  def mentioned(cred, room_id, count) do
    with {:ok, %{"messages" => msgs}} when is_list(msgs) <-
           get(cred, "/api/v1/chat.getMentionedMessages", roomId: room_id, count: count)
           |> shape() do
      {:ok, msgs}
    end
  end

  @doc """
  Whether a username is a bot account, as far as the API shows it to a regular user
  (`users.info` returns `type`: `bot` or `app`; roles are admin-only). Cached for a day.
  """
  def bot_user?(cred, username) do
    Cache.fetch({:rc_user_type, username}, :timer.hours(24), fn ->
      case get(cred, "/api/v1/users.info", username: username) do
        {:ok, %{"user" => user}} ->
          {:ok, user["type"] in ["bot", "app"] or "bot" in (user["roles"] || [])}

        error ->
          error
      end
    end)
  end

  defp shape({:ok, body}) when is_map(body), do: {:ok, body}
  defp shape({:ok, _}), do: {:error, :unexpected_response}
  defp shape(error), do: error

  @doc "The browser link of a room (and message)."
  def room_url(%{"t" => "d", "_id" => rid}, msg_id), do: link("direct/#{rid}", msg_id)
  def room_url(%{"t" => "d", "rid" => rid}, msg_id), do: link("direct/#{rid}", msg_id)
  def room_url(%{"t" => "p", "name" => name}, msg_id), do: link("group/#{name}", msg_id)

  def room_url(%{"name" => name}, msg_id) when is_binary(name),
    do: link("channel/#{name}", msg_id)

  def room_url(_room, _msg_id), do: base_url()

  defp link(path, nil), do: "#{base_url()}/#{path}"
  defp link(path, msg_id), do: "#{base_url()}/#{path}?msg=#{URI.encode_www_form(msg_id)}"

  @doc "A Rocket.Chat timestamp (ISO string or `{\"$date\": ms}`) as a DateTime."
  def ts(%{"$date" => ms}) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)

  def ts(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def ts(_), do: nil
end
