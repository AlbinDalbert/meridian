defmodule MeridianWeb.Admin.SessionHTML do
  use MeridianWeb, :html

  def new(assigns) do
    ~H"""
    <Layouts.app flash={@flash} signed_in={false}>
      <div class="login">
        <.header>
          Admin
          <:subtitle>Paste the deployment's <code>ADMIN_TOKEN</code> to continue.</:subtitle>
        </.header>
        <.form for={%{}} action={~p"/admin/login"} class="card">
          <.input
            type="password"
            name="token"
            id="token"
            value=""
            label="Admin token"
            autocomplete="current-password"
            autofocus
            required
          />
          <.button>Log in</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
