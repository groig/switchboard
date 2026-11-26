defmodule Switchboard.Tools.SendMessage do
  @moduledoc "Posts a Rocket.Chat message as the person, to a channel they belong to or a person."
  use Switchboard.Tools.Support

  alias Switchboard.RocketChat

  @impl true
  def name, do: "send_message"
  @impl true
  def title, do: "Send a Rocket.Chat message"
  @impl true
  def description,
    do:
      "Posts a message in Rocket.Chat as you, with your own token: to a channel you are a member " <>
        "of (#channel) or to a person (@username). @all, @here and @everyone are refused; up to " <>
        "#{RocketChat.max_message()} characters. This speaks for the user: before calling it, " <>
        "show them the exact text and destination and get their explicit OK (confirm first)."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "to" => %{"type" => "string", "description" => "#channel or @username."},
        "text" => %{"type" => "string", "description" => "The message (Rocket.Chat Markdown)."}
      },
      "required" => ["to", "text"]
    }
  end

  @impl true
  def annotations,
    do: %{read_only: false, destructive: false, idempotent: false, open_world: true}

  @impl true
  def connections, do: [:rocketchat]

  # Messages, DMs especially, can be private: the audit log keeps "[redacted]".
  @impl true
  def sensitive_args, do: ["text"]

  @impl true
  def example do
    %{
      args: %{"to" => "#demo-dev", "text" => "DEMO-12 is on staging, ready for QA."},
      output: "Sent to #demo-dev as you: https://chat.example.com/channel/demo-dev?msg=abc123"
    }
  end

  @impl true
  def call(scope, %{"to" => to, "text" => text}) do
    text = String.trim(text)

    with true <- text != "" || {:error, "text must not be empty"},
         true <-
           String.length(text) <= RocketChat.max_message() ||
             {:error, "text is longer than #{RocketChat.max_message()} characters"},
         :ok <- no_mass_mention(text),
         {:ok, cred} <- cred(scope, :rocketchat) do
      case RocketChat.post_as(cred, to, text) do
        {:ok, %{"room" => room, "permalink" => link}} ->
          {:ok, "Sent to #{room} as you: #{link}"}

        {:error, :not_member} ->
          {:error, "You are not a member of #{to}; Switchboard only posts where you can."}

        {:error, :no_channel} ->
          {:error, "Rocket.Chat has no channel #{to} you can see."}

        {:error, :invalid_target} ->
          {:error, "to must be #channel or @username."}

        {:error, reason} ->
          {:error, problem(:rocketchat, reason)}
      end
    end
  end

  defp no_mass_mention(text) do
    if RocketChat.mass_mention?(text),
      do: {:error, "@all, @here and @everyone are not allowed through Switchboard."},
      else: :ok
  end
end
