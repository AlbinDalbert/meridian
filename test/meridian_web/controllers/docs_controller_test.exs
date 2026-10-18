defmodule MeridianWeb.DocsControllerTest do
  use MeridianWeb.ConnCase, async: true

  alias MeridianWeb.Docs

  test "/docs opens the first page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/docs")) == hd(Docs.pages()).path
  end

  test "a page has its content, every page in the sidebar, and its contents", %{conn: conn} do
    conn = get(conn, ~p"/docs/extensions/hooks")
    html = html_response(conn, 200)
    document = LazyHTML.from_document(html)

    assert document |> LazyHTML.query("article.docs h1") |> LazyHTML.text() =~ "Hooks"

    sidebar = document |> LazyHTML.query(".sidebar a.nav-item") |> LazyHTML.attribute("href")
    assert sidebar == Enum.map(Docs.pages(), & &1.path)

    toc = document |> LazyHTML.query(".docs-toc a") |> LazyHTML.attribute("href")
    assert "#tool_callcall-ctx" in toc

    pager = document |> LazyHTML.query(".docs-pager a") |> LazyHTML.attribute("href")
    assert pager == ["/docs/extensions/runs", "/docs/extensions/tools"]

    # Public: no session.
    assert get_resp_header(conn, "set-cookie") == []
    assert [_csp] = get_resp_header(conn, "content-security-policy")
  end

  test "unknown pages aren't found", %{conn: conn} do
    assert conn |> get(~p"/docs/extensions/nope") |> response(404)
    assert conn |> get(~p"/docs/nope/hooks") |> response(404)
  end
end
