defmodule MeridianWeb.Me.AccessRequestController do
  @moduledoc """
  The public request page, `/me/request`: anyone can leave their email (and a name) to ask to
  be added. The operator answers in the admin console (see `Meridian.AccessRequests`).

  Whatever the email, a valid one gets the same answer, so the page doesn't reveal who already
  has access.
  """
  use MeridianWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias Meridian.AccessRequests

  plug :put_root_layout, html: {MeridianWeb.Layouts, :public_root}

  def new(conn, _params), do: render_page(conn, form())

  def create(conn, %{"request" => params}) when is_map(params) do
    case AccessRequests.request_access(params) do
      {:ok, :requested} ->
        render_page(conn, form(), sent: params["email"])

      {:error, :full} ->
        conn
        |> put_status(:service_unavailable)
        |> render_page(form(params),
          error: "Meridian isn't taking requests right now. Try again later."
        )

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_page(to_form(changeset, as: "request"))
    end
  end

  def create(conn, _params), do: create(conn, %{"request" => %{}})

  defp form(params \\ %{}), do: to_form(AccessRequests.change_request(params), as: "request")

  defp render_page(conn, form, opts \\ []) do
    sent = opts[:sent]

    render(conn, :new,
      page_title: if(sent, do: "Request sent", else: "Request access"),
      form: form,
      sent: sent,
      error: opts[:error]
    )
  end
end
