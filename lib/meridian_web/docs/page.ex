defmodule MeridianWeb.Docs.Page do
  @moduledoc """
  A docs page: one markdown file of `docs/guide`, rendered to HTML. Only used at compile time
  (see `MeridianWeb.Docs`), so the markdown library isn't part of the release.

  The file's first `# heading` is the page's title, and its `## headings` are the page's table
  of contents. Links to other pages are written as relative links to their files
  (`03-scripts.md#settings`, `../02-api/01-intro.md`), so they also work on GitHub, and
  rewritten here to the pages' paths.
  """

  @type t :: %__MODULE__{
          section: String.t(),
          slug: String.t(),
          path: String.t(),
          title: String.t(),
          toc: [{id :: String.t(), title :: String.t()}],
          html: String.t()
        }

  defstruct [:section, :slug, :path, :title, :toc, :html]

  @doc "Renders `file`. Its folder is its section (e.g. `docs/guide/01-extensions`)."
  @spec from_file(Path.t()) :: t()
  def from_file(file) do
    section = file |> Path.dirname() |> Path.basename() |> slug()
    slug = file |> Path.basename(".md") |> slug()

    html =
      file
      |> File.read!()
      |> MDEx.to_html!(extension: [table: true, header_id_prefix: ""])
      |> rewrite_links(section)

    %__MODULE__{
      section: section,
      slug: slug,
      path: "/docs/#{section}/#{slug}",
      title: title(html, file),
      toc: toc(html),
      html: html
    }
  end

  @doc "A file or folder name without its ordering prefix: `03-scripts` is `scripts`."
  def slug(name), do: String.replace(name, ~r/^\d+-/, "")

  defp title(html, file) do
    case Regex.run(~r{<h1[^>]*>(.*?)</h1>}s, html) do
      [_, title] -> text(title)
      nil -> raise "#{file} needs a `# Title` line"
    end
  end

  defp toc(html) do
    for [_, id, title] <- Regex.scan(~r{<h2 id="([^"]+)">(.*?)</h2>}s, html),
        do: {id, text(title)}
  end

  # The heading's text, without its markup (and the anchor link MDEx adds).
  defp text(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(["&amp;", "&lt;", "&gt;", "&quot;", "&#39;"], fn
      "&amp;" -> "&"
      "&lt;" -> "<"
      "&gt;" -> ">"
      "&quot;" -> "\""
      "&#39;" -> "'"
    end)
  end

  # `04-runs.md#x` → `/docs/<section>/runs#x`; `../02-api/01-intro.md` → `/docs/api/intro`.
  defp rewrite_links(html, section) do
    Regex.replace(
      ~r{href="(?:\.\./([\w-]+)/)?([\w-]+)\.md(#[^"]*)?"},
      html,
      fn _, other_section, page, anchor ->
        section = if other_section == "", do: section, else: slug(other_section)
        ~s(href="/docs/#{section}/#{slug(page)}#{anchor}")
      end
    )
  end
end
