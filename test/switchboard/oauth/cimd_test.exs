defmodule Switchboard.OAuth.CIMDTest do
  # Changes the global resolver config.
  use ExUnit.Case, async: false

  alias Switchboard.OAuth.CIMD

  @url "https://client.example.com/oauth/metadata.json"
  @doc_body %{
    "client_id" => @url,
    "client_name" => "Example",
    "redirect_uris" => ["http://localhost/callback"],
    "token_endpoint_auth_method" => "none"
  }

  setup do
    original = Application.get_env(:switchboard, CIMD)
    on_exit(fn -> Application.put_env(:switchboard, CIMD, original) end)
    :ok
  end

  defp put_resolver(ips) do
    Application.put_env(
      :switchboard,
      CIMD,
      Keyword.put(Application.get_env(:switchboard, CIMD), :resolver, fn _ -> {:ok, ips} end)
    )
  end

  test "accepts only https URLs with a host name" do
    assert {:error, :invalid_url} = CIMD.fetch("http://client.example.com/m.json")
    assert {:error, :invalid_url} = CIMD.fetch("https://127.0.0.1/m.json")
    assert {:error, :invalid_url} = CIMD.fetch("https://[::1]/m.json")
    assert {:error, :invalid_url} = CIMD.fetch("https://user:pw@client.example.com/m.json")
  end

  test "refuses hosts that resolve to private or loopback addresses" do
    for ip <- [
          {127, 0, 0, 1},
          {10, 1, 2, 3},
          {192, 168, 1, 1},
          {172, 20, 0, 1},
          {169, 254, 169, 254},
          {100, 100, 1, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFD00, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
        ] do
      put_resolver([{93, 184, 215, 14}, ip])

      assert {:error, :forbidden_address} = CIMD.fetch(@url),
             "expected #{inspect(ip)} to be refused"
    end
  end

  test "fetches and validates a document" do
    put_resolver([{93, 184, 215, 14}])

    Req.Test.stub(CIMD, fn conn ->
      assert conn.host == "93.184.215.14"
      assert Plug.Conn.get_req_header(conn, "host") == ["client.example.com"]
      Req.Test.json(conn, @doc_body)
    end)

    assert {:ok, %{client_name: "Example", redirect_uris: ["http://localhost/callback"]}} =
             CIMD.fetch(@url)
  end

  test "rejects a document whose client_id is not its URL" do
    put_resolver([{93, 184, 215, 14}])

    Req.Test.stub(
      CIMD,
      &Req.Test.json(&1, %{@doc_body | "client_id" => "https://other.example/m.json"})
    )

    assert {:error, :invalid_document} = CIMD.fetch(@url)
  end

  test "caps the body size" do
    put_resolver([{93, 184, 215, 14}])

    Req.Test.stub(
      CIMD,
      &Req.Test.json(&1, Map.put(@doc_body, "padding", String.duplicate("a", 20_000)))
    )

    assert {:error, :too_large} = CIMD.fetch(@url)
  end

  test "does not follow redirects" do
    put_resolver([{93, 184, 215, 14}])

    Req.Test.stub(CIMD, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :bad_status} = CIMD.fetch(@url)
  end
end
