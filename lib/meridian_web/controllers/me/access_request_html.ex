defmodule MeridianWeb.Me.AccessRequestHTML do
  use MeridianWeb, :html

  # Laid out like xebec's login: a masthead over a small dialog. Styles in public.css.
  def new(assigns) do
    ~H"""
    <div class="scrim">
      <.masthead sub="request access" />

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
end
