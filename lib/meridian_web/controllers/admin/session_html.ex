defmodule MeridianWeb.Admin.SessionHTML do
  use MeridianWeb, :html

  alias MeridianWeb.AdminAuth

  # A front-door page like the request page (public.css), in the admin console's green.
  def new(assigns) do
    assigns =
      Map.merge(assigns, %{
        oidc_login: AdminAuth.oidc_login?(),
        token_login: AdminAuth.token_login?()
      })

    ~H"""
    <div class="scrim">
      <.masthead sub="admin console" />
      <div class="dialog">
        <div class="bar">Operator sign-in</div>
        <div class="content">
          <%= if @oidc_login do %>
            <p>Sign in with your organization's account.</p>
            <%!-- A link, not a form: the CSP's form-action would block the redirect to the provider. --%>
            <div class="actions">
              <a href={~p"/admin/auth/oidc"} class="btn primary">Sign in</a>
            </div>
            <details :if={@token_login} class="token">
              <summary>Use the admin token instead</summary>
              <.token_form />
            </details>
          <% else %>
            <p>Paste the deployment's <code>ADMIN_TOKEN</code> to continue.</p>
            <.token_form autofocus />
          <% end %>
          <p :if={Phoenix.Flash.get(@flash, :error)} class="error">
            ▲ {Phoenix.Flash.get(@flash, :error)}
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :autofocus, :boolean, default: false

  defp token_form(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/admin/login"}>
      <input
        type="password"
        name="token"
        id="token"
        placeholder="Admin token"
        aria-label="Admin token"
        autocomplete="current-password"
        autofocus={@autofocus}
        required
      />
      <div class="actions">
        <button class="btn primary">Log in</button>
      </div>
    </.form>
    """
  end
end
