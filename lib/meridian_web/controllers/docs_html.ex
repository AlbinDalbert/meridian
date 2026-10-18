defmodule MeridianWeb.DocsHTML do
  use MeridianWeb, :html

  # The page's HTML is rendered from the repo's markdown at compile time (raw HTML in it is
  # dropped), so it's trusted.
  def show(assigns) do
    ~H"""
    <Layouts.docs current_path={@page.path}>
      <div class="docs-page">
        <article class="docs">
          {raw(@page.html)}

          <nav class="docs-pager" aria-label="Pages">
            <a :if={@previous} href={@previous.path} class="docs-previous">
              <span class="muted">Previous</span> {@previous.title}
            </a>
            <a :if={@next} href={@next.path} class="docs-next">
              <span class="muted">Next</span> {@next.title}
            </a>
          </nav>
        </article>

        <aside :if={@page.toc != []} class="docs-toc" aria-label="On this page">
          <p class="nav-label">On this page</p>
          <a :for={{id, title} <- @page.toc} href={"#" <> id}>{title}</a>
        </aside>
      </div>
    </Layouts.docs>
    """
  end
end
