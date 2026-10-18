defmodule MeridianWeb.Docs.PageTest do
  use ExUnit.Case, async: true

  alias MeridianWeb.Docs.Page

  @tag :tmp_dir
  test "a markdown file as a page", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "02-some-section")
    File.mkdir_p!(dir)
    file = Path.join(dir, "03-a-page.md")

    File.write!(file, """
    # The `title`

    See [settings](01-other.md#settings), [the API](../04-api/01-intro.md), and
    [Lua](https://www.lua.org/). <script>alert(1)</script>

    ## First & foremost

    ## Second
    """)

    page = Page.from_file(file)

    assert %Page{section: "some-section", slug: "a-page", title: "The title"} = page
    assert page.path == "/docs/some-section/a-page"
    assert page.toc == [{"first--foremost", "First & foremost"}, {"second", "Second"}]
    assert page.html =~ ~s(href="/docs/some-section/other#settings")
    assert page.html =~ ~s(href="/docs/api/intro")
    assert page.html =~ ~s(href="https://www.lua.org/")
    refute page.html =~ "<script>"
  end

  test "a page needs a title", %{} do
    file = Path.join(System.tmp_dir!(), "untitled-#{System.unique_integer([:positive])}.md")
    File.write!(file, "No title here.\n")
    on_exit(fn -> File.rm(file) end)

    assert_raise RuntimeError, ~r/needs a `# Title` line/, fn -> Page.from_file(file) end
  end
end
