defmodule MeridianWeb.Api.ThreadController do
  @moduledoc "`/api/threads`: the current user's threads."
  use MeridianWeb, :controller

  alias Meridian.{Runs, Threads}

  action_fallback MeridianWeb.Api.FallbackController

  def index(conn, params) do
    threads = Threads.list_threads(conn.assigns.current_user, limit: params["limit"])
    render(conn, :index, threads: threads)
  end

  def create(conn, _params) do
    %{current_user: user, current_policy: policy} = conn.assigns

    with {:ok, thread} <- Threads.create_thread(user, policy, conn.body_params) do
      conn
      |> put_status(:created)
      |> render(:show, thread: thread)
    end
  end

  def show(conn, %{"id" => id}) do
    with %{} = thread <- Threads.get_user_thread(conn.assigns.current_user, id) do
      render(conn, :show, thread: thread, active_run: Runs.get_active_run(thread))
    end
  end

  def update(conn, %{"id" => id}) do
    %{current_user: user, current_policy: policy} = conn.assigns

    with %{} = thread <- Threads.get_user_thread(user, id),
         {:ok, thread} <- Threads.update_thread(thread, policy, conn.body_params) do
      render(conn, :show, thread: thread, active_run: Runs.get_active_run(thread))
    end
  end

  def delete(conn, %{"id" => id}) do
    with %{} = thread <- Threads.get_user_thread(conn.assigns.current_user, id),
         {:ok, _thread} <- Threads.delete_thread(thread) do
      send_resp(conn, :no_content, "")
    end
  end
end
