defmodule MeridianWeb.Me.AccessRequestHTML do
  use MeridianWeb, :html

  # Laid out like xebec's login: a masthead over a small dialog. Styles in public.css.
  def new(assigns) do
    ~H"""
    <div class="scrim">
      <div class="masthead">
        <.mark />
        <div class="word">MERIDIAN</div>
        <div class="sub">request access</div>
      </div>

      <div :if={@sent} class="dialog">
        <div class="bar">Request sent</div>
        <div class="content">
          <p>Thanks! Once you're let in, sign in with <strong>{@sent}</strong>.</p>
          <div class="actions">
            <a class="btn primary" href={~p"/me/login"}>Sign in</a>
          </div>
        </div>
      </div>

      <.form :if={!@sent} for={@form} action={~p"/me/request"} class="dialog">
        <div class="bar">Request access</div>
        <div class="content">
          <p>Leave your email and you'll be added once someone says yes.</p>
          <input
            type="email"
            name={@form[:email].name}
            value={@form[:email].value}
            placeholder="you@example.com"
            aria-label="Email"
            autocomplete="email"
            maxlength="320"
            autofocus
            required
          />
          <p :for={message <- errors(@form[:email])} class="error">▲ Email {message}</p>
          <input
            type="text"
            name={@form[:name].name}
            value={@form[:name].value}
            placeholder="Name (optional)"
            aria-label="Name"
            autocomplete="name"
            maxlength="200"
          />
          <p :for={message <- errors(@form[:name])} class="error">▲ Name {message}</p>
          <p :if={@error} class="error">▲ {@error}</p>
          <div class="actions">
            <button class="btn primary">Request access</button>
            <a class="link" href={~p"/me/login"}>Already in? Sign in</a>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp errors(field), do: Enum.map(field.errors, &translate_error/1)

  # Meridian's mark: a globe, its night side under the meridian ring of a desk globe, tilted
  # like the Earth (23.4°). The ring spans 140° around the tilted axis; the lit side faces away
  # from it, with the terminator curving into the night. The earlier, symmetric mark is kept in
  # docs/brand/mark-symmetric.svg.
  defp mark(assigns) do
    ~H"""
    <svg class="mark" viewBox="0 0 16 16" width="88" height="88" aria-hidden="true">
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
