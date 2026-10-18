defmodule MeridianWeb.Api.ThreadController do
  @moduledoc """
  `/api/threads`: the current user's threads, and what reshapes them: forking a copy,
  truncating the history, and replying again to the last user message.
  """
  use MeridianWeb, :controller

  alias Meridian.{Runs, Threads}
  alias MeridianWeb.Api.RunJSON

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

  @doc "Copies the thread, with its messages through `through` (all of them if not given)."
  def fork(conn, %{"id" => id} = params) do
    with %{} = thread <- Threads.get_user_thread(conn.assigns.current_user, id),
         {:ok, fork} <- Threads.fork_thread(thread, params["through"]) do
      conn
      |> put_status(:created)
      |> render(:show, thread: fork)
    end
  end

  @doc "Deletes the messages after the one with id `after`."
  def truncate(conn, %{"id" => id} = params) do
    with %{} = thread <- Threads.get_user_thread(conn.assigns.current_user, id),
         {:ok, _count} <- Threads.truncate_thread(thread, params["after"]) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc "Starts a run replying to the thread's last message, which must be a user message."
  def reply(conn, %{"id" => id}) do
    %{current_user: user, current_policy: policy} = conn.assigns

    with %{} = thread <- Threads.get_user_thread(user, id),
         {:ok, run} <- Threads.reply(thread, policy) do
      conn
      |> put_status(:accepted)
      |> put_view(RunJSON)
      |> render(:show, run: run)
    end
  end
end
