defmodule MeridianWeb.BrandComponents do
  @moduledoc """
  Meridian's mark and the masthead of its front-door pages (the request page and the admin
  login), styled by `priv/static/assets/public.css`. The colors come from the page's theme, so
  the same mark is amber on the request page and green on the admin login.
  """
  use Phoenix.Component

  @doc "The mark over the spaced-out wordmark and a line saying what the page is."
  attr :sub, :string, required: true

  def masthead(assigns) do
    ~H"""
    <div class="masthead">
      <.mark />
      <div class="word">MERIDIAN</div>
      <div class="sub">{@sub}</div>
    </div>
    """
  end

  @doc """
  Meridian's mark: a globe, its night side under the meridian ring of a desk globe, tilted like
  the Earth (23.4°). The ring spans 140° around the tilted axis; the lit side faces away from
  it, with the terminator curving into the night. The earlier, symmetric mark is kept in
  docs/brand/mark-symmetric.svg.
  """
  attr :size, :integer, default: 88

  def mark(assigns) do
    ~H"""
    <svg class="mark" viewBox="0 0 16 16" width={@size} height={@size} aria-hidden="true">
      <path class="ring" d="M2.62 2.92 A7.4 7.4 0 0 1 15.39 8.44 L13.59 8.33 A5.6 5.6 0 0 0 3.93 4.15 Z" />
      <circle class="night" cx="8" cy="8" r="4.6" />
      <path
        class="day"
        transform="rotate(113.4 8 8)"
        d="M8 3.4 A4.6 4.6 0 0 1 8 12.6 A1.38 4.6 0 0 1 8 3.4 Z"
      />
    </svg>
    """
  end
end
