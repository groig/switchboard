defmodule Switchboard.Tools.NotifyMe do
  @moduledoc """
  A Rocket.Chat direct message to the caller from the bot user. The only write that uses a service
  credential, and it can only ever message the caller.
  """
  use Switchboard.Tools.Support
  use Gettext, backend: SwitchboardWeb.Gettext

  alias Switchboard.{Connections, RateLimit, RocketChat}

  @max 1_000
  @per_hour 30

  @impl true
  def name, do: "notify_me"
  @impl true
  def title, do: "Notify me in Rocket.Chat"
  @impl true
  def description,
    do:
      "Sends you (only you) a short direct message in Rocket.Chat from the bot user, e.g. " <>
        "when a long task finishes. It needs no Rocket.Chat key of yours. It only messages the " <>
        "user who asked, so their request is the confirmation; up to #{@max} characters, " <>
        "#{@per_hour} per hour."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "description" => "The notice, plain text."}
      },
      "required" => ["text"]
    }
  end

  @impl true
  def annotations,
    do: %{read_only: false, destructive: false, idempotent: false, open_world: true}

  @impl true
  def connections, do: []

  @impl true
  def example do
    %{
      args: %{"text" => "The CI run for demo/app#42 passed."},
      output: "Sent you a direct message in Rocket.Chat (as @ana)."
    }
  end

  @impl true
  def call(scope, %{"text" => text}) do
    text = String.trim(text)

    with true <- text != "" || {:error, "text must not be empty"},
         true <- String.length(text) <= @max || {:error, "text is longer than #{@max} characters"},
         :ok <- hourly(scope),
         {:ok, username} <- recipient(scope),
         :ok <- RocketChat.notify(username, notice(scope, text)) |> rc_error() do
      {:ok, "Sent you a direct message in Rocket.Chat (as @#{username})."}
    end
  end

  defp hourly(scope) do
    case RateLimit.take({scope.user.id, :notify_me_hour}, @per_hour, :timer.hours(1)) do
      :ok -> :ok
      {:error, _} -> {:error, "notify_me is limited to #{@per_hour} messages an hour. Try later."}
    end
  end

  @doc """
  The caller's Rocket.Chat username: from their linked Rocket.Chat key when it matched their
  email, otherwise the Rocket.Chat user with their Forgejo username, if its display name is
  their Forgejo name. Never anyone else.
  """
  def recipient(scope) do
    user = scope.user

    case Connections.get(user, "rocketchat") do
      %{identity_matches: true, identity: %{"username" => username}} when is_binary(username) ->
        {:ok, username}

      _ ->
        case RocketChat.user_info(user.username) do
          {:ok, %{"username" => rc, "name" => name, "active" => active}}
          when active != false and is_binary(name) ->
            if same_name?(name, user.name),
              do: {:ok, rc},
              else: {:error, unknown()}

          {:error, :not_configured} ->
            {:error, problem(:rocketchat, :not_configured)}

          _ ->
            {:error, unknown()}
        end
    end
  end

  defp unknown,
    do:
      "Switchboard can't tell which Rocket.Chat user is you. Link Rocket.Chat at " <>
        Switchboard.OAuth.issuer() <> "/connections and try again."

  defp same_name?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  defp same_name?(_, _), do: false

  @doc "The notice text: the message without mentions, then the automatic-notice line."
  def notice(scope, text) do
    footer =
      Gettext.with_locale(SwitchboardWeb.Gettext, scope.user.locale, fn ->
        gettext("Automatic notice from Switchboard. Replies here aren't read.")
      end)

    RocketChat.defuse_mentions(text) <> "\n\n_" <> footer <> "_"
  end

  defp rc_error(:ok), do: :ok
  defp rc_error({:error, reason}), do: {:error, problem(:rocketchat, reason)}
end
