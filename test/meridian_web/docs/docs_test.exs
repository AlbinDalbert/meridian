defmodule MeridianWeb.DocsTest do
  # The docs' content: links between pages and example scripts must keep working.
  use ExUnit.Case, async: true

  alias Meridian.Extensions.Script
  alias MeridianWeb.Docs

  test "links to other pages point to a page and a heading that exist" do
    ids =
      Map.new(Docs.pages(), fn page ->
        {page.path, Regex.scan(~r/ id="([^"]+)"/, page.html) |> Enum.map(&Enum.at(&1, 1))}
      end)

    for page <- Docs.pages(),
        [_, path, anchor] <- Regex.scan(~r{href="(/docs/[^"#]*)(?:#([^"]*))?"}, page.html) do
      assert Map.has_key?(ids, path), "#{page.path} links to #{path}, which doesn't exist"

      if anchor,
        do: assert(anchor in ids[path], "#{page.path} links to #{path}##{anchor}: no heading")
    end
  end

  test "links within a page point to a heading on it" do
    for page <- Docs.pages(), [_, anchor] <- Regex.scan(~r{href="#([^"]+)"}, page.html) do
      assert page.html =~ ~s( id="#{anchor}"), "#{page.path} links to a missing ##{anchor}"
    end
  end

  test "complete example scripts load" do
    scripts =
      for file <- Path.wildcard("docs/guide/*/*.md"),
          [_, code] <- Regex.scan(~r/```lua\n(.*?)```/s, File.read!(file)),
          code = dedent(code),
          String.starts_with?(code, "local M") and String.ends_with?(code, "return M\n"),
          do: {file, code}

    assert length(scripts) >= 5

    for {file, code} <- scripts do
      assert {:ok, _script} = Script.load(code), "an example in #{file} doesn't load"
    end
  end

  # Code blocks inside list items are indented.
  defp dedent(code) do
    indent = code |> String.split("\n") |> hd() |> then(&Regex.run(~r/^ */, &1)) |> hd()
    code |> String.split("\n") |> Enum.map_join("\n", &String.replace_prefix(&1, indent, ""))
  end
end
