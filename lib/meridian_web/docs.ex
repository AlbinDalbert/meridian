defmodule MeridianWeb.Docs do
  @moduledoc """
  The docs under `/docs`: the markdown files of `docs/guide`, rendered when Meridian is
  compiled (see `MeridianWeb.Docs.Page`).

  Each folder is a section and each file a page, both ordered by their number prefix:
  `docs/guide/01-extensions/03-scripts.md` is the third page of the first section, at
  `/docs/extensions/scripts`. Adding a page or a section is adding a file or a folder.
  """

  alias MeridianWeb.Docs.Page

  @guide Path.expand("../../docs/guide", __DIR__)
  @files @guide |> Path.join("*/*.md") |> Path.wildcard() |> Enum.sort()

  for file <- @files, do: @external_resource(file)

  @pages Enum.map(@files, &Page.from_file/1)

  @sections @files
            |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
            |> Enum.uniq()
            |> Enum.map(fn dir ->
              slug = Page.slug(dir)
              {slug, slug |> String.replace("-", " ") |> String.capitalize()}
            end)

  # Recompile when a page is added or removed (changed ones are `@external_resource`s).
  def __mix_recompile__?,
    do: @guide |> Path.join("*/*.md") |> Path.wildcard() |> Enum.sort() != @files

  @doc "Every page, in order."
  @spec pages() :: [Page.t()]
  def pages, do: @pages

  @doc "The sections, in order: `{slug, label}`. A section's label is its folder's name."
  def sections, do: @sections

  @doc "The page at `/docs/<section>/<slug>`, or nil."
  @spec page(String.t(), String.t()) :: Page.t() | nil
  def page(section, slug), do: Enum.find(@pages, &(&1.section == section and &1.slug == slug))

  @doc "The pages before and after `page`, or nil at either end."
  def neighbours(%Page{} = page) do
    index = Enum.find_index(@pages, &(&1 == page))
    {if(index > 0, do: Enum.at(@pages, index - 1)), Enum.at(@pages, index + 1)}
  end
end
