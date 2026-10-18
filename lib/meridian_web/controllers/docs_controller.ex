defmodule MeridianWeb.DocsController do
  @moduledoc "The docs pages (see `MeridianWeb.Docs`). Public: they're the repo's docs."
  use MeridianWeb, :controller

  alias MeridianWeb.Docs

  def index(conn, _params), do: redirect(conn, to: hd(Docs.pages()).path)

  def show(conn, %{"section" => section, "page" => slug}) do
    case Docs.page(section, slug) do
      nil ->
        conn |> put_status(:not_found) |> text("Not Found")

      page ->
        {previous, next} = Docs.neighbours(page)
        render(conn, :show, page_title: page.title, page: page, previous: previous, next: next)
    end
  end
end
