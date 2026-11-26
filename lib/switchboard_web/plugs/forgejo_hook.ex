defmodule SwitchboardWeb.Plugs.ForgejoHook do
  @moduledoc """
  `POST /hooks/forgejo`: Forgejo's webhook for finished Actions runs. Public, so:

    * refused (503) unless `FORGEJO_WEBHOOK_SECRET` is configured;
    * the body is read raw (before `Plug.Parsers`), capped at #{div(1_000_000, 1000)} KB, and its
      `X-Forgejo-Signature` (hex HMAC-SHA256 of the body) is compared in constant time (401);
    * only `application/json` (415);
    * it answers 202 at once; the work is a `Switchboard.Watches.Hint` job.

  Forgejo 16 sends `action_run_success` and `action_run_failure` (also for cancelled and
  skipped runs) once per finished run; `action_run_recover` exists but isn't sent. Forgejo 17
  adds `workflow_run_*` events, accepted too. The payload is only used for the repository's
  `full_name`: a webhook is a hint, never the source of a notice.
  """
  import Plug.Conn

  require Logger

  @max_body 1_000_000
  @events ~w(action_run_success action_run_failure action_run_recover
             workflow_run_success workflow_run_failure workflow_run_cancelled workflow_run_skipped)

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["hooks", "forgejo"]} = conn, _opts) do
    conn |> handle() |> halt()
  end

  def call(conn, _opts), do: conn

  defp handle(%Plug.Conn{method: "POST"} = conn) do
    with {:ok, secret} <- secret(),
         :ok <- json?(conn),
         {:ok, body, conn} <- read(conn),
         :ok <- verify(conn, body, secret) do
      event = conn |> get_req_header("x-forgejo-event") |> List.first()
      hint(event, body)
      reply(conn, 202, "accepted")
    else
      {:error, :not_configured} -> reply(conn, 503, "webhook not configured")
      {:error, :media_type} -> reply(conn, 415, "use application/json")
      {:error, :too_large, conn} -> reply(conn, 413, "too large")
      {:error, :bad_body, conn} -> reply(conn, 400, "bad request")
      {:error, :signature} -> reply(conn, 401, "bad signature")
    end
  end

  defp handle(conn), do: conn |> put_resp_header("allow", "POST") |> reply(405, "POST only")

  defp secret do
    case Application.get_env(:switchboard, :forgejo_webhook_secret) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :not_configured}
    end
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> if type =~ ~r{^application/json}i, do: :ok, else: {:error, :media_type}
      [] -> {:error, :media_type}
    end
  end

  defp read(conn) do
    case read_body(conn, length: @max_body, read_length: 64_000, read_timeout: 5_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :too_large, conn}
      {:error, _} -> {:error, :bad_body, conn}
    end
  end

  defp verify(conn, body, secret) do
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    case get_req_header(conn, "x-forgejo-signature") do
      [given | _] ->
        if Plug.Crypto.secure_compare(String.downcase(String.trim(given)), expected),
          do: :ok,
          else: {:error, :signature}

      [] ->
        {:error, :signature}
    end
  end

  defp hint(event, body) when event in @events do
    with {:ok, payload} <- Jason.decode(body),
         repo when is_binary(repo) <- get_in(payload, ["run", "repository", "full_name"]),
         {:ok, _owner, _name} <- Switchboard.Forgejo.parse_repo(repo) do
      Oban.insert(Switchboard.Watches.Hint.new(%{repo: String.downcase(repo)}))
    else
      _ -> Logger.info("Forgejo webhook #{event} without a usable repository")
    end
  end

  defp hint(_event, _body), do: :ignored

  defp reply(conn, status, text) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, text)
  end
end
