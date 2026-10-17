defmodule MeridianWeb.Admin.SessionHTML do
  use MeridianWeb, :html

  alias MeridianWeb.AdminAuth

  def new(assigns) do
    assigns =
      Map.merge(assigns, %{
        oidc_login: AdminAuth.oidc_login?(),
        token_login: AdminAuth.token_login?()
      })

    ~H"""
    <Layouts.app flash={@flash} signed_in={false}>
      <div class="login">
        <.header>
          Admin
          <:subtitle :if={@oidc_login}>Sign in with your organization's account.</:subtitle>
          <:subtitle :if={!@oidc_login}>
            Paste the deployment's <code>ADMIN_TOKEN</code> to continue.
          </:subtitle>
        </.header>
        <%!-- A link, not a form: the CSP's form-action would block the redirect to the provider. --%>
        <section :if={@oidc_login} class="card">
          <a href={~p"/admin/auth/oidc"} class="btn btn-primary login-oidc">Sign in</a>
        </section>
        <details :if={@token_login && @oidc_login} class="login-token">
          <summary class="muted">Use the admin token instead</summary>
          <.token_form />
        </details>
        <.token_form :if={@token_login && !@oidc_login} autofocus />
      </div>
    </Layouts.app>
    """
  end

  attr :autofocus, :boolean, default: false

  defp token_form(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/admin/login"} class="card">
      <.input
        type="password"
        name="token"
        id="token"
        value=""
        label="Admin token"
        autocomplete="current-password"
        autofocus={@autofocus}
        required
      />
      <.button>Log in</.button>
    </.form>
    """
  end
end
