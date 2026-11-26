defmodule SwitchboardWeb.Plugs.HealthTest do
  use SwitchboardWeb.ConnCase, async: true

  test "answers the container's own loopback check", %{conn: conn} do
    conn = get(%{conn | remote_ip: {127, 0, 0, 1}}, "/healthz")
    assert json_response(conn, 200) == %{"status" => "ok", "database" => true}
  end

  test "is a 404 through a proxy or from elsewhere", %{conn: conn} do
    proxied =
      %{conn | remote_ip: {127, 0, 0, 1}}
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> get("/healthz")

    assert proxied.status == 404
    assert get(%{build_conn() | remote_ip: {203, 0, 113, 9}}, "/healthz").status == 404
  end
end
