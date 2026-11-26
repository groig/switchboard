defmodule Switchboard.OAuth.CIMD do
  @moduledoc """
  Fetches OAuth Client ID Metadata Documents (CIMD) without becoming an SSRF vector.

  The `client_id` of a CIMD client is an HTTPS URL that we fetch while handling an authorization
  request, so an attacker controls the URL. The fetch therefore:

    * accepts only `https://` URLs with a host name (no IP literals, credentials or fragments);
    * resolves the host once, refuses private, loopback, link-local, CGNAT, multicast and
      reserved addresses, and connects to the address it checked (the TLS name is still the host),
      so DNS rebinding cannot swap in an internal address between check and connect;
    * follows no redirects, caps the body (`@max_bytes`) and the total time (`@timeout`);
    * requires the document's `client_id` to equal the URL it was fetched from.
  """

  @max_bytes 16_384
  @timeout 5_000

  @type error ::
          :invalid_url
          | :forbidden_address
          | :dns_failure
          | :too_large
          | :timeout
          | :bad_status
          | :invalid_document

  @doc "Whether a client_id looks like a CIMD URL (rather than a DCR-issued id)."
  def cimd_client_id?(client_id),
    do: is_binary(client_id) and String.starts_with?(client_id, "https://")

  @spec fetch(String.t()) :: {:ok, map()} | {:error, error()}
  def fetch(url) do
    with {:ok, uri} <- validate_url(url),
         {:ok, ip} <- resolve(uri.host),
         {:ok, body} <- get(uri, ip),
         {:ok, doc} <- decode(body) do
      validate_document(doc, url)
    end
  end

  @doc false
  def validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil} = uri}
      when is_binary(host) and host != "" and byte_size(url) <= 2048 ->
        if ip_literal?(host), do: {:error, :invalid_url}, else: {:ok, uri}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp ip_literal?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp resolve(host) do
    resolver =
      Application.get_env(:switchboard, __MODULE__, [])[:resolver] || (&default_resolve/1)

    case resolver.(host) do
      {:ok, [_ | _] = ips} ->
        # Every address must be public, otherwise a mixed answer could still route inward.
        if Enum.all?(ips, &public_ip?/1), do: {:ok, hd(ips)}, else: {:error, :forbidden_address}

      _ ->
        {:error, :dns_failure}
    end
  end

  defp default_resolve(host) do
    charlist = String.to_charlist(host)

    ips =
      for family <- [:inet, :inet6],
          {:ok, ips} <- [:inet.getaddrs(charlist, family)],
          ip <- ips,
          do: ip

    if ips == [], do: {:error, :nxdomain}, else: {:ok, ips}
  end

  @doc "Whether an address is publicly routable (not private, loopback, link-local, ...)."
  def public_ip?({a, b, _, _} = ip) when tuple_size(ip) == 4 do
    not (a == 0 or a == 10 or a == 127 or a >= 224 or
           (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or
           (a == 192 and b == 168) or
           (a == 192 and b == 0) or
           (a == 198 and b in 18..19))
  end

  def public_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: public_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  def public_ip?({a, _, _, _, _, _, _, _} = ip) when tuple_size(ip) == 8 do
    not (ip == {0, 0, 0, 0, 0, 0, 0, 0} or ip == {0, 0, 0, 0, 0, 0, 0, 1} or
           Bitwise.band(a, 0xFE00) == 0xFC00 or
           Bitwise.band(a, 0xFFC0) == 0xFE80 or
           Bitwise.band(a, 0xFF00) == 0xFF00 or
           a == 0x2001 or a == 0x0064)
  end

  def public_ip?(_), do: false

  defp get(uri, ip) do
    host_header = if uri.port in [nil, 443], do: uri.host, else: "#{uri.host}:#{uri.port}"

    ip_host =
      ip |> :inet.ntoa() |> to_string() |> then(&if(tuple_size(ip) == 8, do: "[#{&1}]", else: &1))

    options =
      [
        url: %{uri | host: ip_host} |> URI.to_string(),
        headers: [{"host", host_header}, {"accept", "application/json"}],
        connect_options: [hostname: uri.host, timeout: @timeout],
        receive_timeout: @timeout,
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        into: &collect_capped/2
      ]
      |> Keyword.merge(Application.get_env(:switchboard, __MODULE__, [])[:req_options] || [])

    task = Task.async(fn -> Req.get(options) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %Req.Response{status: 200} = resp}} ->
        if resp.private[:cimd_too_large],
          do: {:error, :too_large},
          else: {:ok, IO.iodata_to_binary(resp.body)}

      {:ok, {:ok, _}} ->
        {:error, :bad_status}

      {:ok, {:error, _}} ->
        {:error, :bad_status}

      nil ->
        {:error, :timeout}
    end
  end

  defp collect_capped({:data, data}, {req, resp}) do
    body = [resp.body || "" | data]

    if IO.iodata_length(body) > @max_bytes do
      {:halt, {req, %{resp | body: [], private: Map.put(resp.private, :cimd_too_large, true)}}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> {:error, :invalid_document}
    end
  end

  defp validate_document(doc, url) do
    redirect_uris = doc["redirect_uris"]

    # A metadata document cannot carry a secret, so it must be a public client.
    valid? =
      doc["client_id"] == url and
        is_list(redirect_uris) and redirect_uris != [] and length(redirect_uris) <= 10 and
        Enum.all?(redirect_uris, &is_binary/1) and
        doc["token_endpoint_auth_method"] in [nil, "none"]

    if valid? do
      {:ok,
       %{
         client_name: doc["client_name"] |> string_or_nil() |> truncate(200),
         client_uri: string_or_nil(doc["client_uri"]),
         redirect_uris: redirect_uris,
         metadata:
           Map.take(
             doc,
             ~w(client_id client_name client_uri redirect_uris grant_types response_types token_endpoint_auth_method scope logo_uri)
           )
       }}
    else
      {:error, :invalid_document}
    end
  end

  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(_), do: nil

  defp truncate(nil, _), do: nil
  defp truncate(s, n), do: String.slice(s, 0, n)
end
